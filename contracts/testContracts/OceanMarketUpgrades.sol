/* solium-disable */
pragma solidity 0.4.25;

import '../OceanMarket.sol';



contract OceanMarketExtraFunctionality is OceanMarket{
    //returns a number
    function getNumber() public view returns(uint) {
        return 42;
    }
}

contract OceanMarketChangeInStorage is OceanMarket{
    // keep track of how many times a function was called.
    mapping (address=>uint256) public called;
}

contract OceanMarketChangeInStorageAndLogic is Initializable, Ownable {

    using SafeMath for uint256;
    using SafeMath for uint;

    // ============
    // DATA STRUCTURES:
    // ============
    struct Asset {
        address owner;  // owner of the Asset
        uint256 price;  // price of asset
        bool active;    // status of asset
    }

    mapping(bytes32 => Asset) private mAssets;           // mapping assetId to Asset struct

    struct Payment {
        address sender;             // payment sender
        address receiver;           // provider or anyone (set by the sender of funds)
        PaymentState state;         // payment state
        uint256 amount;             // amount of tokens to be transferred
        uint256 date;               // timestamp of the payment event (in sec.)
        uint256 expiration;         // consumer may request refund after expiration timestamp (in sec.)
    }
    enum PaymentState {Locked, Released, Refunded}
    mapping(bytes32 => Payment) private mPayments;  // mapping from id to associated payment struct

    // limit period for reques of tokens
    mapping(address => uint256) private tokenRequest; // mapping from address to last time of request
    uint256 maxAmount;         // max amount of tokens user can get for each request
    uint256 minPeriod;                        // min amount of time to wait before request token again

    // limit access to refund payment
    address private authAddress;

    // marketplace global variables
    OceanToken  public  mToken;

    // ============
    // EVENTS:
    // ============
    event AssetRegistered(bytes32 indexed _assetId, address indexed _owner);
    event FrequentTokenRequest(address indexed _requester, uint256 _minPeriod);
    event LimitTokenRequest(address indexed _requester, uint256 _amount, uint256 _maxAmount);
    event PaymentReceived(bytes32 indexed _paymentId, address indexed _receiver, uint256 _amount, uint256 _expire);
    event PaymentReleased(bytes32 indexed _paymentId, address indexed _receiver);
    event PaymentRefunded(bytes32 indexed _paymentId, address indexed _sender);

    mapping (address=>uint256) public called;

    // ============
    // modifier:
    // ============
    modifier validAddress(address sender) {
        require(sender != address(0x0), 'Sender address is 0x0.');
        _;
    }

    modifier isLocked(bytes32 _paymentId) {
        require(mPayments[_paymentId].state == PaymentState.Locked, 'State is not Locked');
        _;
    }

    modifier isAuthContract() {
        require(
            msg.sender == authAddress || msg.sender == address(this), 'Sender is not an authorized contract.'
        );
        _;
    }

    /**
    * @dev OceanMarket Initializer
    * @param _tokenAddress The deployed contract address of OceanToken
    * Runs only on initial contract deployment.
    */
    function initialize(address _tokenAddress, address _owner) public initializer() {
        require(_tokenAddress != address(0x0), 'Token address is 0x0.');
        require(_owner != address(0x0), 'Owner address is 0x0.');
        // instantiate Ocean token contract
        mToken = OceanToken(_tokenAddress);
        // set the token receiver to be marketplace
        mToken.setReceiver(address(this));
        // Set owner
        Ownable.initialize(_owner);
        // max amount of tokens user can get for each request
        maxAmount = 10000 * 10 ** 18;
        // min amount of time to wait before request token again
        minPeriod = 0;

    }

    /**
    * @dev provider register the new asset
    * @param assetId the integer identifier of new asset
    * @param price the integer representing price of new asset
    * @return valid Boolean indication of registration of new asset
    */
    function register(bytes32 assetId, uint256 price) public validAddress(msg.sender) returns (bool success) {
        require(mAssets[assetId].owner == address(0), 'Owner address is not 0x0.');
        mAssets[assetId] = Asset(msg.sender, price, false);
        mAssets[assetId].active = true;

        emit AssetRegistered(assetId, msg.sender);
        return true;
    }

    /**
    * @dev sender tranfer payment to OceanMarket contract
    * @param _paymentId the integer identifier of payment
    * @param _receiver the address of receiver
    * @param _amount the payment amount
    * @param _expire the expiration time in seconds
    * @return valid Boolean indication of payment is transferred
    */
    function sendPayment(
        bytes32 _paymentId,
        address _receiver,
        uint256 _amount,
        uint256 _expire) public validAddress(msg.sender) returns (bool) {
        // consumer make payment to Market contract
        require(mToken.transferFrom(msg.sender, address(this), _amount), 'Token transferFrom failed.');
        /* solium-disable-next-line security/no-block-members */
        mPayments[_paymentId] = Payment(msg.sender, _receiver, PaymentState.Locked, _amount, block.timestamp, _expire);
        emit PaymentReceived(_paymentId, _receiver, _amount, _expire);
        return true;
    }

    /**
    * @dev the consumer release payment to receiver
    * @param _paymentId the integer identifier of payment
    * @return valid Boolean indication of payment is released
    */
    function releasePayment(bytes32 _paymentId) public isLocked(_paymentId) isAuthContract() returns (bool) {
        // update state to avoid re-entry attack
        mPayments[_paymentId].state = PaymentState.Released;
        require(mToken.transfer(mPayments[_paymentId].receiver, mPayments[_paymentId].amount), 'Token transfer failed.');
        emit PaymentReleased(_paymentId, mPayments[_paymentId].receiver);
        return true;
    }

    /**
    * @dev the consumer get refunded payment from OceanMarket contract
    * @param _paymentId the integer identifier of payment
    * @return valid Boolean indication of payment is refunded
    */
    function refundPayment(bytes32 _paymentId) public isLocked(_paymentId) isAuthContract() returns (bool) {
        // refund payment to consumer
        mPayments[_paymentId].state = PaymentState.Refunded;
        require(mToken.transfer(mPayments[_paymentId].sender, mPayments[_paymentId].amount), 'Token transfer failed.');
        emit PaymentRefunded(_paymentId, mPayments[_paymentId].sender);
        return true;
    }

    /**
    * @dev verify the payment of consumer is received by OceanMarket
    * @param _paymentId the integer identifier of payment
    * @return valid Boolean indication of payment is received
    */
    function verifyPaymentReceived(bytes32 _paymentId) public view returns (bool) {
        called[msg.sender] += 1;
        if (mPayments[_paymentId].state == PaymentState.Locked) {
            return true;
        }
        return false;
    }

    /**
    * @dev user can request some tokens for testing
    * @param amount the amount of tokens to be requested
    * @return valid Boolean indication of tokens are requested
    */
    function requestTokens(uint256 amount) public validAddress(msg.sender) returns (bool) {
        /* solium-disable-next-line security/no-block-members */
        if (block.timestamp < tokenRequest[msg.sender] + minPeriod) {
            emit FrequentTokenRequest(msg.sender, minPeriod);
            return false;
        }
        // amount should not exceed maxAmount
        if (amount > maxAmount) {
            require(mToken.transfer(msg.sender, maxAmount), 'Token transfer failed.');
            emit LimitTokenRequest(msg.sender, amount, maxAmount);
        } else {
            require(mToken.transfer(msg.sender, amount), 'Token transfer failed.');
        }
        /* solium-disable-next-line security/no-block-members */
        tokenRequest[msg.sender] = block.timestamp;
        return true;
    }

    /**
    * @dev Owner can limit the amount and time for token request in Testing
    * @param _amount the max amount of tokens that can be requested
    * @param _period the min amount of time before next request
    */
    function limitTokenRequest(uint _amount, uint _period) public onlyOwner() {
        // set min period of time before next request (in seconds)
        minPeriod = _period;
        // set max amount for each request
        maxAmount = _amount;
    }

    /**
    * @dev OceanRegistry changes the asset status according to the voting result
    * @param assetId the integer identifier of asset in the voting
    * @return valid Boolean indication of asset is whitelisted
    */
    function deactivateAsset(bytes32 assetId) public returns (bool){
        // disable asset if it is not whitelisted in the registry
        mAssets[assetId].active = false;
        return true;
    }

    /**
    * @dev OceanMarket add the deployed address of OceanAuth contract
    * @return valid Boolean indication of contract address is updated
    */
    function addAuthAddress() public validAddress(msg.sender) returns (bool) {
        // authAddress can only be set at deployment of Auth contract - only once
        require(authAddress == address(0), 'authAddress is not 0x0');
        authAddress = msg.sender;
        return true;
    }

    /**
    * @dev OceanMarket generates bytes32 identifier for asset
    * @param contents the meta data information of asset as string
    * @return bytes32 as the identifier of asset
    */
    function generateId(string contents) public pure returns (bytes32) {
        // Generate the hash of input string
        return bytes32(keccak256(abi.encodePacked(contents)));
    }

    /**
    * @dev OceanMarket generates bytes32 identifier for asset
    * @param contents the meta data information of asset as bytes
    * @return bytes32 as the identifier of asset
    */
    function generateId(bytes contents) public pure returns (bytes32) {
        // Generate the hash of input bytes
        return bytes32(keccak256(abi.encodePacked(contents)));
    }

    /**
    * @dev OceanMarket check status of asset
    * @param assetId the integer identifier of asset
    * @return valid Boolean indication of asset is active or not
    */
    function checkAsset(bytes32 assetId) public view returns (bool) {
        return mAssets[assetId].active;
    }

    /**
    * @dev OceanMarket check price of asset
    * @param assetId the integer identifier of asset
    * @return integer as price of asset
    */
    function getAssetPrice(bytes32 assetId) public view returns (uint256) {
        return mAssets[assetId].price;
    }

}


contract OceanMarketWithBug is Initializable, Ownable {

    using SafeMath for uint256;
    using SafeMath for uint;

    // ============
    // DATA STRUCTURES:
    // ============
    struct Asset {
        address owner;  // owner of the Asset
        uint256 price;  // price of asset
        bool active;    // status of asset
    }

    mapping(bytes32 => Asset) private mAssets;           // mapping assetId to Asset struct

    struct Payment {
        address sender;             // payment sender
        address receiver;           // provider or anyone (set by the sender of funds)
        PaymentState state;         // payment state
        uint256 amount;             // amount of tokens to be transferred
        uint256 date;               // timestamp of the payment event (in sec.)
        uint256 expiration;         // consumer may request refund after expiration timestamp (in sec.)
    }
    enum PaymentState {Locked, Released, Refunded}
    mapping(bytes32 => Payment) private mPayments;  // mapping from id to associated payment struct

    // limit period for reques of tokens
    mapping(address => uint256) private tokenRequest; // mapping from address to last time of request
    uint256 maxAmount;         // max amount of tokens user can get for each request
    uint256 minPeriod;                        // min amount of time to wait before request token again

    // limit access to refund payment
    address private authAddress;

    // marketplace global variables
    OceanToken  public  mToken;

    // ============
    // EVENTS:
    // ============
    event AssetRegistered(bytes32 indexed _assetId, address indexed _owner);
    event FrequentTokenRequest(address indexed _requester, uint256 _minPeriod);
    event LimitTokenRequest(address indexed _requester, uint256 _amount, uint256 _maxAmount);
    event PaymentReceived(bytes32 indexed _paymentId, address indexed _receiver, uint256 _amount, uint256 _expire);
    event PaymentReleased(bytes32 indexed _paymentId, address indexed _receiver);
    event PaymentRefunded(bytes32 indexed _paymentId, address indexed _sender);

    // ============
    // modifier:
    // ============
    modifier validAddress(address sender) {
        require(sender != address(0x0), 'Sender address is 0x0.');
        _;
    }

    modifier isLocked(bytes32 _paymentId) {
        require(mPayments[_paymentId].state == PaymentState.Locked, 'State is not Locked');
        _;
    }

    modifier isAuthContract() {
        require(
            msg.sender == authAddress || msg.sender == address(this), 'Sender is not an authorized contract.'
        );
        _;
    }

    /**
    * @dev OceanMarket Initializer
    * @param _tokenAddress The deployed contract address of OceanToken
    * Runs only on initial contract deployment.
    */
    function initialize(address _tokenAddress, address _owner) public initializer() {
        require(_tokenAddress != address(0x0), 'Token address is 0x0.');
        require(_owner != address(0x0), 'Owner address is 0x0.');
        // instantiate Ocean token contract
        mToken = OceanToken(_tokenAddress);
        // set the token receiver to be marketplace
        mToken.setReceiver(address(this));
        // Set owner
        Ownable.initialize(_owner);
        // max amount of tokens user can get for each request
        maxAmount = 10000 * 10 ** 18;
        // min amount of time to wait before request token again
        minPeriod = 0;

    }

    /**
    * @dev provider register the new asset
    * @param assetId the integer identifier of new asset
    * @param price the integer representing price of new asset
    * @return valid Boolean indication of registration of new asset
    */
    function register(bytes32 assetId, uint256 price) public validAddress(msg.sender) returns (bool success) {
        require(mAssets[assetId].owner == address(0), 'Owner address is not 0x0.');
        mAssets[assetId] = Asset(msg.sender, price, false);
        mAssets[assetId].active = true;

        emit AssetRegistered(assetId, msg.sender);
        return true;
    }

    /**
    * @dev sender tranfer payment to OceanMarket contract
    * @param _paymentId the integer identifier of payment
    * @param _receiver the address of receiver
    * @param _amount the payment amount
    * @param _expire the expiration time in seconds
    * @return valid Boolean indication of payment is transferred
    */
    function sendPayment(
        bytes32 _paymentId,
        address _receiver,
        uint256 _amount,
        uint256 _expire) public validAddress(msg.sender) returns (bool) {
        // consumer make payment to Market contract
        require(mToken.transferFrom(msg.sender, address(this), _amount), 'Token transferFrom failed.');
        /* solium-disable-next-line security/no-block-members */
        mPayments[_paymentId] = Payment(msg.sender, _receiver, PaymentState.Locked, _amount, block.timestamp, _expire);
        emit PaymentReceived(_paymentId, _receiver, _amount, _expire);
        return true;
    }

    /**
    * @dev the consumer release payment to receiver
    * @param _paymentId the integer identifier of payment
    * @return valid Boolean indication of payment is released
    */
    function releasePayment(bytes32 _paymentId) public isLocked(_paymentId) isAuthContract() returns (bool) {
        // update state to avoid re-entry attack
        mPayments[_paymentId].state = PaymentState.Released;
        require(mToken.transfer(mPayments[_paymentId].receiver, mPayments[_paymentId].amount), 'Token transfer failed.');
        emit PaymentReleased(_paymentId, mPayments[_paymentId].receiver);
        return true;
    }

    /**
    * @dev the consumer get refunded payment from OceanMarket contract
    * @param _paymentId the integer identifier of payment
    * @return valid Boolean indication of payment is refunded
    */
    function refundPayment(bytes32 _paymentId) public isLocked(_paymentId) isAuthContract() returns (bool) {
        // refund payment to consumer
        mPayments[_paymentId].state = PaymentState.Refunded;
        require(mToken.transfer(mPayments[_paymentId].sender, mPayments[_paymentId].amount), 'Token transfer failed.');
        emit PaymentRefunded(_paymentId, mPayments[_paymentId].sender);
        return true;
    }

    /**
    * @dev verify the payment of consumer is received by OceanMarket
    * @param _paymentId the integer identifier of payment
    * @return valid Boolean indication of payment is received
    */
    function verifyPaymentReceived(bytes32 _paymentId) public view returns (bool) {
        return false;
        if (mPayments[_paymentId].state == PaymentState.Locked) {
            return true;
        }
        return false;
    }

    /**
    * @dev user can request some tokens for testing
    * @param amount the amount of tokens to be requested
    * @return valid Boolean indication of tokens are requested
    */
    function requestTokens(uint256 amount) public validAddress(msg.sender) returns (bool) {
        /* solium-disable-next-line security/no-block-members */
        if (block.timestamp < tokenRequest[msg.sender] + minPeriod) {
            emit FrequentTokenRequest(msg.sender, minPeriod);
            return false;
        }
        // amount should not exceed maxAmount
        if (amount > maxAmount) {
            require(mToken.transfer(msg.sender, maxAmount), 'Token transfer failed.');
            emit LimitTokenRequest(msg.sender, amount, maxAmount);
        } else {
            require(mToken.transfer(msg.sender, amount), 'Token transfer failed.');
        }
        /* solium-disable-next-line security/no-block-members */
        tokenRequest[msg.sender] = block.timestamp;
        return true;
    }

    /**
    * @dev Owner can limit the amount and time for token request in Testing
    * @param _amount the max amount of tokens that can be requested
    * @param _period the min amount of time before next request
    */
    function limitTokenRequest(uint _amount, uint _period) public onlyOwner() {
        // set min period of time before next request (in seconds)
        minPeriod = _period;
        // set max amount for each request
        maxAmount = _amount;
    }

    /**
    * @dev OceanRegistry changes the asset status according to the voting result
    * @param assetId the integer identifier of asset in the voting
    * @return valid Boolean indication of asset is whitelisted
    */
    function deactivateAsset(bytes32 assetId) public returns (bool){
        // disable asset if it is not whitelisted in the registry
        mAssets[assetId].active = false;
        return true;
    }

    /**
    * @dev OceanMarket add the deployed address of OceanAuth contract
    * @return valid Boolean indication of contract address is updated
    */
    function addAuthAddress() public validAddress(msg.sender) returns (bool) {
        // authAddress can only be set at deployment of Auth contract - only once
        require(authAddress == address(0), 'authAddress is not 0x0');
        authAddress = msg.sender;
        return true;
    }

    /**
    * @dev OceanMarket generates bytes32 identifier for asset
    * @param contents the meta data information of asset as string
    * @return bytes32 as the identifier of asset
    */
    function generateId(string contents) public pure returns (bytes32) {
        // Generate the hash of input string
        return bytes32(keccak256(abi.encodePacked(contents)));
    }

    /**
    * @dev OceanMarket generates bytes32 identifier for asset
    * @param contents the meta data information of asset as bytes
    * @return bytes32 as the identifier of asset
    */
    function generateId(bytes contents) public pure returns (bytes32) {
        // Generate the hash of input bytes
        return bytes32(keccak256(abi.encodePacked(contents)));
    }

    /**
    * @dev OceanMarket check status of asset
    * @param assetId the integer identifier of asset
    * @return valid Boolean indication of asset is active or not
    */
    function checkAsset(bytes32 assetId) public view returns (bool) {
        return mAssets[assetId].active;
    }

    /**
    * @dev OceanMarket check price of asset
    * @param assetId the integer identifier of asset
    * @return integer as price of asset
    */
    function getAssetPrice(bytes32 assetId) public view returns (uint256) {
        return mAssets[assetId].price;
    }

}


contract OceanMarketChangeFunctionSignature is Initializable, Ownable {

    using SafeMath for uint256;
    using SafeMath for uint;

    // ============
    // DATA STRUCTURES:
    // ============
    struct Asset {
        address owner;  // owner of the Asset
        uint256 price;  // price of asset
        bool active;    // status of asset
    }

    mapping(bytes32 => Asset) private mAssets;           // mapping assetId to Asset struct

    struct Payment {
        address sender;             // payment sender
        address receiver;           // provider or anyone (set by the sender of funds)
        PaymentState state;         // payment state
        uint256 amount;             // amount of tokens to be transferred
        uint256 date;               // timestamp of the payment event (in sec.)
        uint256 expiration;         // consumer may request refund after expiration timestamp (in sec.)
    }
    enum PaymentState {Locked, Released, Refunded}
    mapping(bytes32 => Payment) private mPayments;  // mapping from id to associated payment struct

    // limit period for reques of tokens
    mapping(address => uint256) private tokenRequest; // mapping from address to last time of request
    uint256 maxAmount;         // max amount of tokens user can get for each request
    uint256 minPeriod;                        // min amount of time to wait before request token again

    // limit access to refund payment
    address private authAddress;

    // marketplace global variables
    OceanToken  public  mToken;

    // ============
    // EVENTS:
    // ============
    event AssetRegistered(bytes32 indexed _assetId, address indexed _owner);
    event FrequentTokenRequest(address indexed _requester, uint256 _minPeriod);
    event LimitTokenRequest(address indexed _requester, uint256 _amount, uint256 _maxAmount);
    event PaymentReceived(bytes32 indexed _paymentId, address indexed _receiver, uint256 _amount, uint256 _expire);
    event PaymentReleased(bytes32 indexed _paymentId, address indexed _receiver);
    event PaymentRefunded(bytes32 indexed _paymentId, address indexed _sender);

    // ============
    // modifier:
    // ============
    modifier validAddress(address sender) {
        require(sender != address(0x0), 'Sender address is 0x0.');
        _;
    }

    modifier isLocked(bytes32 _paymentId) {
        require(mPayments[_paymentId].state == PaymentState.Locked, 'State is not Locked');
        _;
    }

    modifier isAuthContract() {
        require(
            msg.sender == authAddress || msg.sender == address(this), 'Sender is not an authorized contract.'
        );
        _;
    }

    /**
    * @dev OceanMarket Initializer
    * @param _tokenAddress The deployed contract address of OceanToken
    * Runs only on initial contract deployment.
    */
    function initialize(address _tokenAddress, address _owner) public initializer() {
        require(_tokenAddress != address(0x0), 'Token address is 0x0.');
        require(_owner != address(0x0), 'Owner address is 0x0.');
        // instantiate Ocean token contract
        mToken = OceanToken(_tokenAddress);
        // set the token receiver to be marketplace
        mToken.setReceiver(address(this));
        // Set owner
        Ownable.initialize(_owner);
        // max amount of tokens user can get for each request
        maxAmount = 10000 * 10 ** 18;
        // min amount of time to wait before request token again
        minPeriod = 0;

    }

    /**
    * @dev provider register the new asset
    * @param assetId the integer identifier of new asset
    * @param price the integer representing price of new asset
    * @return valid Boolean indication of registration of new asset
    */
    function register(bytes32 assetId, uint256 price) public validAddress(msg.sender) returns (bool success) {
        require(mAssets[assetId].owner == address(0), 'Owner address is not 0x0.');
        mAssets[assetId] = Asset(msg.sender, price, false);
        mAssets[assetId].active = true;

        emit AssetRegistered(assetId, msg.sender);
        return true;
    }

    /**
    * @dev sender tranfer payment to OceanMarket contract
    * @param _paymentId the integer identifier of payment
    * @param _receiver the address of receiver
    * @param _amount the payment amount
    * @param _expire the expiration time in seconds
    * @return valid Boolean indication of payment is transferred
    */
    function sendPayment(
        bytes32 _paymentId,
        address _receiver,
        uint256 _amount,
        uint256 _expire) public validAddress(msg.sender) returns (bool) {
        // consumer make payment to Market contract
        require(mToken.transferFrom(msg.sender, address(this), _amount), 'Token transferFrom failed.');
        /* solium-disable-next-line security/no-block-members */
        mPayments[_paymentId] = Payment(msg.sender, _receiver, PaymentState.Locked, _amount, block.timestamp, _expire);
        emit PaymentReceived(_paymentId, _receiver, _amount, _expire);
        return true;
    }

    /**
    * @dev the consumer release payment to receiver
    * @param _paymentId the integer identifier of payment
    * @return valid Boolean indication of payment is released
    */
    function releasePayment(bytes32 _paymentId) public isLocked(_paymentId) isAuthContract() returns (bool) {
        // update state to avoid re-entry attack
        mPayments[_paymentId].state = PaymentState.Released;
        require(mToken.transfer(mPayments[_paymentId].receiver, mPayments[_paymentId].amount), 'Token transfer failed.');
        emit PaymentReleased(_paymentId, mPayments[_paymentId].receiver);
        return true;
    }

    /**
    * @dev the consumer get refunded payment from OceanMarket contract
    * @param _paymentId the integer identifier of payment
    * @return valid Boolean indication of payment is refunded
    */
    function refundPayment(bytes32 _paymentId) public isLocked(_paymentId) isAuthContract() returns (bool) {
        // refund payment to consumer
        mPayments[_paymentId].state = PaymentState.Refunded;
        require(mToken.transfer(mPayments[_paymentId].sender, mPayments[_paymentId].amount), 'Token transfer failed.');
        emit PaymentRefunded(_paymentId, mPayments[_paymentId].sender);
        return true;
    }

    /**
    * @dev verify the payment of consumer is received by OceanMarket
    * @param _paymentId the integer identifier of payment
    * @param _flg test flag if true returns true
    * @return valid Boolean indication of payment is received
    */
    function verifyPaymentReceived(bytes32 _paymentId, bool _flg) public view returns (bool) {
        if (_flg == true) return true;
        if (mPayments[_paymentId].state == PaymentState.Locked) {
            return true;
        }
        return false;
    }

    /**
    * @dev user can request some tokens for testing
    * @param amount the amount of tokens to be requested
    * @return valid Boolean indication of tokens are requested
    */
    function requestTokens(uint256 amount) public validAddress(msg.sender) returns (bool) {
        /* solium-disable-next-line security/no-block-members */
        if (block.timestamp < tokenRequest[msg.sender] + minPeriod) {
            emit FrequentTokenRequest(msg.sender, minPeriod);
            return false;
        }
        // amount should not exceed maxAmount
        if (amount > maxAmount) {
            require(mToken.transfer(msg.sender, maxAmount), 'Token transfer failed.');
            emit LimitTokenRequest(msg.sender, amount, maxAmount);
        } else {
            require(mToken.transfer(msg.sender, amount), 'Token transfer failed.');
        }
        /* solium-disable-next-line security/no-block-members */
        tokenRequest[msg.sender] = block.timestamp;
        return true;
    }

    /**
    * @dev Owner can limit the amount and time for token request in Testing
    * @param _amount the max amount of tokens that can be requested
    * @param _period the min amount of time before next request
    */
    function limitTokenRequest(uint _amount, uint _period) public onlyOwner() {
        // set min period of time before next request (in seconds)
        minPeriod = _period;
        // set max amount for each request
        maxAmount = _amount;
    }

    /**
    * @dev OceanRegistry changes the asset status according to the voting result
    * @param assetId the integer identifier of asset in the voting
    * @return valid Boolean indication of asset is whitelisted
    */
    function deactivateAsset(bytes32 assetId) public returns (bool){
        // disable asset if it is not whitelisted in the registry
        mAssets[assetId].active = false;
        return true;
    }

    /**
    * @dev OceanMarket add the deployed address of OceanAuth contract
    * @return valid Boolean indication of contract address is updated
    */
    function addAuthAddress() public validAddress(msg.sender) returns (bool) {
        // authAddress can only be set at deployment of Auth contract - only once
        require(authAddress == address(0), 'authAddress is not 0x0');
        authAddress = msg.sender;
        return true;
    }

    /**
    * @dev OceanMarket generates bytes32 identifier for asset
    * @param contents the meta data information of asset as string
    * @return bytes32 as the identifier of asset
    */
    function generateId(string contents) public pure returns (bytes32) {
        // Generate the hash of input string
        return bytes32(keccak256(abi.encodePacked(contents)));
    }

    /**
    * @dev OceanMarket generates bytes32 identifier for asset
    * @param contents the meta data information of asset as bytes
    * @return bytes32 as the identifier of asset
    */
    function generateId(bytes contents) public pure returns (bytes32) {
        // Generate the hash of input bytes
        return bytes32(keccak256(abi.encodePacked(contents)));
    }

    /**
    * @dev OceanMarket check status of asset
    * @param assetId the integer identifier of asset
    * @return valid Boolean indication of asset is active or not
    */
    function checkAsset(bytes32 assetId) public view returns (bool) {
        return mAssets[assetId].active;
    }

    /**
    * @dev OceanMarket check price of asset
    * @param assetId the integer identifier of asset
    * @return integer as price of asset
    */
    function getAssetPrice(bytes32 assetId) public view returns (uint256) {
        return mAssets[assetId].price;
    }

}
