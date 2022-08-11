// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.4;

import {RaiUSDChainlinkOracle} from "./RaiOracle.sol";
import {ERC20} from "@oz/token/ERC20/ERC20.sol";
import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "@oz/token/ERC20/utils/SafeERC20.sol";

/**
 *
 * @dev The PEG is a rebasing wrapper for RAI.
 *
 *      Users deposit the "underlying" (RAI) tokens and are
 *      minted PEG tokens with elastic balances
 *      which change up or down when the value of the underlying token changes.
 *
 *      For example: Manny “wraps” 1 RAI when the price of RAI is $3.
 *      Manny receives 3 PEG tokens in return.
 *      The overall value of their PEG is the same as their original RAI,
 *      however each unit is now priced at exactly $1. The next day,
 *      the price of RAI changes to $4. PEG system detects
 *      this price change, and rebases such that Manny’s balance is
 *      now 4 PEG tokens, still priced at $1 each.
 *
 *      The PEG math is almost identical to Ampleforth's μFragments.
 *
 *      For AMPL, internal balances are represented using `gons` and
 *          -> internal account balance     `_gonBalances[account]`
 *          -> internal supply scalar       `gonsPerFragment = TOTAL_GONS / _totalSupply`
 *          -> public balance               `_gonBalances[account] * gonsPerFragment`
 *          -> public total supply          `_totalSupply`
 *
 *      In our case internal balances are stored as 'bits'.
 *          -> underlying token unit price  `p_u = price / 10 ^ (PRICE_DECIMALS)`
 *          -> total underlying tokens      `_totalUnderlying`
 *          -> internal account balance     `_accountBits[account]`
 *          -> internal supply scalar       `_bitsPerToken`
                                            ` = TOTAL_BITS / (MAX_UNDERLYING*p_u)`
 *                                          ` = BITS_PER_UNDERLYING*(10^PRICE_DECIMALS)/price`
 *                                          ` = PRICE_BITS / price`
 *          -> user's underlying balance    `(_accountBits[account] / BITS_PER_UNDERLYING`
 *          -> public balance               `_accountBits[account] * _bitsPerToken`
 *          -> public total supply          `_totalUnderlying * p_u`
 *
 *
 */
contract PEG is IERC20{
    // PLEASE READ BEFORE CHANGING ANY ACCOUNTING OR MATH
    // We make the following guarantees:
    // - If address 'A' transfers x button tokens to address 'B'.
    //   A's resulting external balance will be decreased by "precisely" x button tokens,
    //   and B's external balance will be "precisely" increased by x button tokens.
    // - If address 'A' deposits y underlying tokens,
    //   A's resulting underlying balance will increase by "precisely" y.
    // - If address 'A' withdraws y underlying tokens,
    //   A's resulting underlying balance will decrease by "precisely" y.
    //
    using SafeERC20 for IERC20;

    //--------------------------------------------------------------------------
    // Constants

    /// @dev The price has a 8 decimal point precision.
    uint256 public constant PRICE_DECIMALS = 8;

    /// @dev Math constants.
    uint256 private constant MAX_UINT256 = type(uint256).max;

    /// @dev The maximum units of the underlying token that can be deposited into this contract
    ///      ie) for a underlying token with 18 decimals, MAX_UNDERLYING is 1B tokens.
    uint256 public constant MAX_UNDERLYING = 1_000_000_000e18;

    /// @dev TOTAL_BITS is a multiple of MAX_UNDERLYING so that {BITS_PER_UNDERLYING} is an integer.
    ///      Use the highest value that fits in a uint256 for max granularity.
    uint256 private constant TOTAL_BITS = MAX_UINT256 - (MAX_UINT256 % MAX_UNDERLYING);

    /// @dev Number of BITS per unit of deposit.
    uint256 private constant BITS_PER_UNDERLYING = TOTAL_BITS / MAX_UNDERLYING;

    /// @dev Number of BITS per unit of deposit * (1 USD).
    uint256 private constant PRICE_BITS = BITS_PER_UNDERLYING * (10**PRICE_DECIMALS);

    /// @dev TRUE_MAX_PRICE = maximum integer < (sqrt(4*PRICE_BITS + 1) - 1) / 2
    ///      Setting MAX_PRICE to the closest two power which is just under TRUE_MAX_PRICE.
    uint256 public constant MAX_PRICE = (2**96 - 1); // (2^96) - 1

    //--------------------------------------------------------------------------
    // Attributes

    // Rai token address
    address public constant underlying = 0x03ab458634910AaD20eF5f1C8ee96F1D6ac54919;
    address public oracle;
    uint256 public lastPrice;

    /// @dev Rebase counter
    uint256 _epoch;

    string public constant name = "PEG";

    string public constant symbol = "PEG";

    /// @dev internal balance, bits issued per account
    mapping(address => uint256) private _accountBits;

    /// @dev ERC20 allowances
    mapping(address => mapping(address => uint256)) private _allowances;


    //--------------------------------------------------------------------------
    // Events
    //--------------------------------------------------------------------------

    /// @notice Event emitted when the balance scalar is updated.
    /// @param epoch The number of rebases since inception.
    /// @param newScalar The new scalar.
    event Rebase(uint256 indexed epoch, uint256 newScalar);

    /// @dev Log to record changes to the oracle.
    /// @param oracle The address of the new oracle.
    event OracleUpdated(address oracle);

    //--------------------------------------------------------------------------
    // Modifiers
    //--------------------------------------------------------------------------

    modifier onAfterRebase() {
        uint256 price;
        bool valid;
        (price, valid) = _queryPrice();
        if (valid) {
            _rebase(price);
        }
        _;
    }

    //--------------------------------------------------------------------------

    /// @param oracle_ The oracle which provides the underlying token price.
    constructor(address oracle_) {
        // MAX_UNDERLYING worth bits are 'pre-mined' to `address(0x)`
        // at the time of construction.
        //
        // During mint, bits are transferred from `address(0x)`
        // and during burn, bits are transferred back to `address(0x)`.
        //
        // No more than MAX_UNDERLYING can be deposited into the PEG contract.
        _accountBits[address(0)] = TOTAL_BITS;

        uint256 price;
        bool valid;

        oracle = oracle_;
        (price, valid) = _queryPrice();
        require(valid, "PEG: unable to fetch data from oracle");

        emit OracleUpdated(oracle);
        _rebase(price);
    }

    //--------------------------------------------------------------------------
    // ERC20 description attributes
    //--------------------------------------------------------------------------
    
    function decimals() external view returns (uint8) {
        return ERC20(underlying).decimals();
    }

    //--------------------------------------------------------------------------
    // ERC-20 token view methods
    //--------------------------------------------------------------------------
    
    function totalSupply() external view override returns (uint256) {
        uint256 price;
        (price, ) = _queryPrice();
        return _bitsToAmount(_activeBits(), price);
    }

    
    function balanceOf(address account) external view override returns (uint256) {
        if (account == address(0)) {
            return 0;
        }
        uint256 price;
        (price, ) = _queryPrice();
        return _bitsToAmount(_accountBits[account], price);
    }

    
    function scaledTotalSupply() external view returns (uint256) {
        return _bitsToUAmount(_activeBits());
    }

    
    function scaledBalanceOf(address account) external view returns (uint256) {
        if (account == address(0)) {
            return 0;
        }
        return _bitsToUAmount(_accountBits[account]);
    }

    
    function allowance(address owner_, address spender) external view override returns (uint256) {
        return _allowances[owner_][spender];
    }

    //--------------------------------------------------------------------------
    // View methods
    //--------------------------------------------------------------------------

    
    function totalUnderlying() external view returns (uint256) {
        return _bitsToUAmount(_activeBits());
    }

    
    function balanceOfUnderlying(address who) external view returns (uint256) {
        if (who == address(0)) {
            return 0;
        }
        return _bitsToUAmount(_accountBits[who]);
    }

    
    function underlyingToWrapper(uint256 uAmount) external view returns (uint256) {
        uint256 price;
        (price, ) = _queryPrice();
        return _bitsToAmount(_uAmountToBits(uAmount), price);
    }

    
    function wrapperToUnderlying(uint256 amount) external view returns (uint256) {
        uint256 price;
        (price, ) = _queryPrice();
        return _bitsToUAmount(_amountToBits(amount, price));
    }

    //--------------------------------------------------------------------------
    // ERC-20 write methods

    
    function transfer(address to, uint256 amount)
        external
        onAfterRebase
        override
        returns (bool)
    {
        _transfer(msg.sender, to, _amountToBits(amount, lastPrice), amount);
        return true;
    }

    
    function transferAll(address to)
        external
        onAfterRebase
        returns (bool)
    {
        uint256 bits = _accountBits[msg.sender];
        _transfer(msg.sender, to, bits, _bitsToAmount(bits, lastPrice));
        return true;
    }

    
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external onAfterRebase override returns (bool) {
        if (_allowances[from][msg.sender] != type(uint256).max) {
            _allowances[from][msg.sender] -= amount;
            emit Approval(from, msg.sender, _allowances[from][msg.sender]);
        }

        _transfer(from, to, _amountToBits(amount, lastPrice), amount);
        return true;
    }


    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedAmount) external returns (bool) {
        _allowances[msg.sender][spender] += addedAmount;

        emit Approval(msg.sender, spender, _allowances[msg.sender][spender]);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedAmount) external returns (bool) {
        if (subtractedAmount >= _allowances[msg.sender][spender]) {
            delete _allowances[msg.sender][spender];
        } else {
            _allowances[msg.sender][spender] -= subtractedAmount;
        }

        emit Approval(msg.sender, spender, _allowances[msg.sender][spender]);
        return true;
    }

    //--------------------------------------------------------------------------
    // RebasingERC20 write methods
    //--------------------------------------------------------------------------

    
    function rebase() external onAfterRebase {
        return;
    }

    //--------------------------------------------------------------------------
    // Write methods
    //--------------------------------------------------------------------------
    
    function mint(uint256 amount) external onAfterRebase returns (uint256) {
        uint256 bits = _amountToBits(amount, lastPrice);
        uint256 uAmount = _bitsToUAmount(bits);
        _deposit(msg.sender, msg.sender, uAmount, amount, bits);
        return uAmount;
    }

    
    function burn(uint256 amount) external onAfterRebase returns (uint256) {
        uint256 bits = _amountToBits(amount, lastPrice);
        uint256 uAmount = _bitsToUAmount(bits);
        _withdraw(msg.sender, msg.sender, uAmount, amount, bits);
        return uAmount;
    }

    
    function burnTo(address to, uint256 amount) external onAfterRebase returns (uint256) {
        uint256 bits = _amountToBits(amount, lastPrice);
        uint256 uAmount = _bitsToUAmount(bits);
        _withdraw(msg.sender, to, uAmount, amount, bits);
        return uAmount;
    }

    
    function burnAll() external onAfterRebase returns (uint256) {
        uint256 bits = _accountBits[msg.sender];
        uint256 uAmount = _bitsToUAmount(bits);
        uint256 amount = _bitsToAmount(bits, lastPrice);
        _withdraw(msg.sender, msg.sender, uAmount, amount, bits);
        return uAmount;
    }

    
    function burnAllTo(address to) external onAfterRebase returns (uint256) {
        uint256 bits = _accountBits[msg.sender];
        uint256 uAmount = _bitsToUAmount(bits);
        uint256 amount = _bitsToAmount(bits, lastPrice);
        _withdraw(msg.sender, to, uAmount, amount, bits);
        return uAmount;
    }

    
    function deposit(uint256 uAmount) external onAfterRebase returns (uint256) {
        uint256 bits = _uAmountToBits(uAmount);
        uint256 amount = _bitsToAmount(bits, lastPrice);
        _deposit(msg.sender, msg.sender, uAmount, amount, bits);
        return amount;
    }

    
    function depositFor(address to, uint256 uAmount)
        external
       
        onAfterRebase
        returns (uint256)
    {
        uint256 bits = _uAmountToBits(uAmount);
        uint256 amount = _bitsToAmount(bits, lastPrice);
        _deposit(msg.sender, to, uAmount, amount, bits);
        return amount;
    }

    
    function withdraw(uint256 uAmount) external onAfterRebase returns (uint256) {
        uint256 bits = _uAmountToBits(uAmount);
        uint256 amount = _bitsToAmount(bits, lastPrice);
        _withdraw(msg.sender, msg.sender, uAmount, amount, bits);
        return amount;
    }

    
    function withdrawTo(address to, uint256 uAmount)
        external
       
        onAfterRebase
        returns (uint256)
    {
        uint256 bits = _uAmountToBits(uAmount);
        uint256 amount = _bitsToAmount(bits, lastPrice);
        _withdraw(msg.sender, to, uAmount, amount, bits);
        return amount;
    }

    
    function withdrawAll() external onAfterRebase returns (uint256) {
        uint256 bits = _accountBits[msg.sender];
        uint256 uAmount = _bitsToUAmount(bits);
        uint256 amount = _bitsToAmount(bits, lastPrice);
        _withdraw(msg.sender, msg.sender, uAmount, amount, bits);
        return amount;
    }

    
    function withdrawAllTo(address to) external onAfterRebase returns (uint256) {
        uint256 bits = _accountBits[msg.sender];
        uint256 uAmount = _bitsToUAmount(bits);
        uint256 amount = _bitsToAmount(bits, lastPrice);
        _withdraw(msg.sender, to, uAmount, amount, bits);
        return amount;
    }

    //--------------------------------------------------------------------------
    // Private methods

    /// @dev Internal method to commit deposit state.
    ///      NOTE: Expects bits, uAmount, amount to be pre-calculated.
    function _deposit(
        address from,
        address to,
        uint256 uAmount,
        uint256 amount,
        uint256 bits
    ) private {
        require(amount > 0, "PEG: too few tokens tokens to mint");

        IERC20(underlying).safeTransferFrom(from, address(this), uAmount);

        _transfer(address(0), to, bits, amount);
    }

    /// @dev Internal method to commit withdraw state.
    ///      NOTE: Expects bits, uAmount, amount to be pre-calculated.
    function _withdraw(
        address from,
        address to,
        uint256 uAmount,
        uint256 amount,
        uint256 bits
    ) private {
        require(amount > 0, "PEG: too few tokens tokens to burn");

        _transfer(from, address(0), bits, amount);

        IERC20(underlying).safeTransfer(to, uAmount);
    }

    /// @dev Internal method to commit transfer state.
    ///      NOTE: Expects bits/amounts to be pre-calculated.
    function _transfer(
        address from,
        address to,
        uint256 bits,
        uint256 amount
    ) private {
        _accountBits[from] -= bits;
        _accountBits[to] += bits;

        emit Transfer(from, to, amount);

        if (_accountBits[from] == 0) {
            delete _accountBits[from];
        }
    }

    /// @dev Updates the `lastPrice` and recomputes the internal scalar.
    function _rebase(uint256 price) private {
        if (price > MAX_PRICE) {
            price = MAX_PRICE;
        }

        lastPrice = price;

        _epoch++;

        emit Rebase(_epoch, price);
    }

    /// @dev Returns the active "un-mined" bits
    function _activeBits() private view returns (uint256) {
        return TOTAL_BITS - _accountBits[address(0)];
    }

    /// @dev Queries the oracle for the latest price
    ///      If fetched oracle price isn't valid returns the last price,
    ///      else returns the new price from the oracle.
    function _queryPrice() private view returns (uint256, bool) {
        uint256 newPrice;
        bool valid;
        (newPrice, valid) = RaiUSDChainlinkOracle(oracle).getData();

        // Note: we consider newPrice == 0 to be invalid because accounting fails with price == 0
        // For example, _bitsPerToken needs to be able to divide by price so a div/0 is caused
        return (valid && newPrice > 0 ? newPrice : lastPrice, valid && newPrice > 0);
    }

    /// @dev Convert button token amount to bits.
    function _amountToBits(uint256 amount, uint256 price) private pure returns (uint256) {
        return amount * _bitsPerToken(price);
    }

    /// @dev Convert underlying token amount to bits.
    function _uAmountToBits(uint256 uAmount) private pure returns (uint256) {
        return uAmount * BITS_PER_UNDERLYING;
    }

    /// @dev Convert bits to button token amount.
    function _bitsToAmount(uint256 bits, uint256 price) private pure returns (uint256) {
        return bits / _bitsPerToken(price);
    }

    /// @dev Convert bits to underlying token amount.
    function _bitsToUAmount(uint256 bits) private pure returns (uint256) {
        return bits / BITS_PER_UNDERLYING;
    }

    /// @dev Internal scalar to convert bits to button tokens.
    function _bitsPerToken(uint256 price) private pure returns (uint256) {
        return PRICE_BITS / price;
    }
}