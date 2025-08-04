// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../hedera/HederaTokenService.sol";
import "../hedera/HederaResponseCodes.sol";

contract HederaDataOracle is HederaTokenService {
    address public owner;
    uint256 public requestCounter;
    uint256 public oracleFee = 1 * 10**8; // 1 HBAR in tinybars
    
    struct DataRequest {
        uint256 id;
        address requester;
        string apiUrl;
        string apiKey; // encrypted or hashed
        string dataPath; // JSON path to extract specific data
        uint256 timestamp;
        bool fulfilled;
        string response;
        uint256 bounty;
    }
    
    struct OracleNode {
        address nodeAddress;
        bool isActive;
        uint256 reputation;
        uint256 totalRequests;
        uint256 successfulRequests;
    }
    
    mapping(uint256 => DataRequest) public dataRequests;
    mapping(address => OracleNode) public oracleNodes;
    mapping(string => uint256) public lastUpdated; // API endpoint -> timestamp
    mapping(string => string) public cachedData; // API endpoint -> cached response
    
    address[] public activeNodes;
    uint256 public cacheExpiry = 300; // 5 minutes
    
    event DataRequested(
        uint256 indexed requestId,
        address indexed requester,
        string apiUrl,
        string dataPath,
        uint256 bounty
    );
    
    event DataFulfilled(
        uint256 indexed requestId,
        address indexed oracle,
        string response
    );
    
    event OracleNodeRegistered(address indexed node);
    event OracleNodeDeactivated(address indexed node);
    event CacheUpdated(string indexed apiUrl, string data);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this");
        _;
    }
    
    modifier onlyActiveOracle() {
        require(oracleNodes[msg.sender].isActive, "Not an active oracle");
        _;
    }
    
    constructor() {
        owner = msg.sender;
        requestCounter = 0;
    }
    
    // Register as an oracle node
    function registerOracleNode() external payable {
        require(msg.value >= 10 * 10**8, "Minimum stake of 10 HBAR required"); // 10 HBAR stake
        require(!oracleNodes[msg.sender].isActive, "Already registered");
        
        oracleNodes[msg.sender] = OracleNode({
            nodeAddress: msg.sender,
            isActive: true,
            reputation: 100,
            totalRequests: 0,
            successfulRequests: 0
        });
        
        activeNodes.push(msg.sender);
        emit OracleNodeRegistered(msg.sender);
    }
    
    // Request data from any API
    function requestData(
        string memory _apiUrl,
        string memory _apiKey,
        string memory _dataPath
    ) external payable returns (uint256) {
        require(msg.value >= oracleFee, "Insufficient fee");
        
        // Check cache first
        string memory cacheKey = string(abi.encodePacked(_apiUrl, _dataPath));
        if (lastUpdated[cacheKey] + cacheExpiry > block.timestamp) {
            // Return cached data immediately
            requestCounter++;
            dataRequests[requestCounter] = DataRequest({
                id: requestCounter,
                requester: msg.sender,
                apiUrl: _apiUrl,
                apiKey: _apiKey,
                dataPath: _dataPath,
                timestamp: block.timestamp,
                fulfilled: true,
                response: cachedData[cacheKey],
                bounty: msg.value
            });
            
            emit DataFulfilled(requestCounter, address(this), cachedData[cacheKey]);
            return requestCounter;
        }
        
        requestCounter++;
        dataRequests[requestCounter] = DataRequest({
            id: requestCounter,
            requester: msg.sender,
            apiUrl: _apiUrl,
            apiKey: _apiKey,
            dataPath: _dataPath,
            timestamp: block.timestamp,
            fulfilled: false,
            response: "",
            bounty: msg.value
        });
        
        emit DataRequested(requestCounter, msg.sender, _apiUrl, _dataPath, msg.value);
        return requestCounter;
    }
    
    // Oracle nodes fulfill data requests
    function fulfillRequest(
        uint256 _requestId,
        string memory _response
    ) external onlyActiveOracle {
        require(_requestId <= requestCounter, "Invalid request ID");
        require(!dataRequests[_requestId].fulfilled, "Request already fulfilled");
        
        DataRequest storage request = dataRequests[_requestId];
        request.fulfilled = true;
        request.response = _response;
        
        // Update cache
        string memory cacheKey = string(abi.encodePacked(request.apiUrl, request.dataPath));
        cachedData[cacheKey] = _response;
        lastUpdated[cacheKey] = block.timestamp;
        
        // Update oracle reputation
        OracleNode storage oracle = oracleNodes[msg.sender];
        oracle.totalRequests++;
        oracle.successfulRequests++;
        oracle.reputation = (oracle.successfulRequests * 100) / oracle.totalRequests;
        
        // Pay oracle
        uint256 payment = (request.bounty * 80) / 100; // 80% to oracle, 20% protocol fee
        payable(msg.sender).transfer(payment);
        
        emit DataFulfilled(_requestId, msg.sender, _response);
        emit CacheUpdated(cacheKey, _response);
    }
    
    // Batch request multiple APIs
    function batchRequestData(
        string[] memory _apiUrls,
        string[] memory _apiKeys,
        string[] memory _dataPaths
    ) external payable returns (uint256[] memory) {
        require(_apiUrls.length == _apiKeys.length && _apiKeys.length == _dataPaths.length, "Array length mismatch");
        require(msg.value >= oracleFee * _apiUrls.length, "Insufficient fee for batch request");
        
        uint256[] memory requestIds = new uint256[](_apiUrls.length);
        uint256 feePerRequest = msg.value / _apiUrls.length;
        
        for (uint256 i = 0; i < _apiUrls.length; i++) {
            requestCounter++;
            dataRequests[requestCounter] = DataRequest({
                id: requestCounter,
                requester: msg.sender,
                apiUrl: _apiUrls[i],
                apiKey: _apiKeys[i],
                dataPath: _dataPaths[i],
                timestamp: block.timestamp,
                fulfilled: false,
                response: "",
                bounty: feePerRequest
            });
            
            requestIds[i] = requestCounter;
            emit DataRequested(requestCounter, msg.sender, _apiUrls[i], _dataPaths[i], feePerRequest);
        }
        
        return requestIds;
    }
    
    // Get request details
    function getRequest(uint256 _requestId) external view returns (
        address requester,
        string memory apiUrl,
        string memory dataPath,
        uint256 timestamp,
        bool fulfilled,
        string memory response
    ) {
        DataRequest memory request = dataRequests[_requestId];
        return (
            request.requester,
            request.apiUrl,
            request.dataPath,
            request.timestamp,
            request.fulfilled,
            request.response
        );
    }
    
    // Get cached data
    function getCachedData(string memory _apiUrl, string memory _dataPath) external view returns (string memory, uint256) {
        string memory cacheKey = string(abi.encodePacked(_apiUrl, _dataPath));
        return (cachedData[cacheKey], lastUpdated[cacheKey]);
    }
    
    // Admin functions
    function updateOracleFee(uint256 _newFee) external onlyOwner {
        oracleFee = _newFee;
    }
    
    function updateCacheExpiry(uint256 _newExpiry) external onlyOwner {
        cacheExpiry = _newExpiry;
    }
    
    function deactivateOracle(address _oracle) external onlyOwner {
        oracleNodes[_oracle].isActive = false;
        emit OracleNodeDeactivated(_oracle);
    }
    
    function withdrawFees() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }
    
    // Get oracle node info
    function getOracleInfo(address _oracle) external view returns (
        bool isActive,
        uint256 reputation,
        uint256 totalRequests,
        uint256 successfulRequests
    ) {
        OracleNode memory oracle = oracleNodes[_oracle];
        return (oracle.isActive, oracle.reputation, oracle.totalRequests, oracle.successfulRequests);
    }
    
    // Get all active oracle nodes
    function getActiveOracles() external view returns (address[] memory) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < activeNodes.length; i++) {
            if (oracleNodes[activeNodes[i]].isActive) {
                activeCount++;
            }
        }
        
        address[] memory result = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < activeNodes.length; i++) {
            if (oracleNodes[activeNodes[i]].isActive) {
                result[index] = activeNodes[i];
                index++;
            }
        }
        
        return result;
    }
}