// SPDX-FileCopyrightText: 2022 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

// See contracts/COMPILERS.md
pragma solidity 0.4.24;

import {AragonApp} from "@aragon/os/contracts/apps/AragonApp.sol";
import {SafeMath} from "@aragon/os/contracts/lib/math/SafeMath.sol";
import {SafeMath64} from "@aragon/os/contracts/lib/math/SafeMath64.sol";
import {UnstructuredStorage} from "@aragon/os/contracts/common/UnstructuredStorage.sol";

import {IStakingModule} from "../interfaces/IStakingModule.sol";
import {INodeOperatorsRegistry} from "../interfaces/INodeOperatorsRegistry.sol";
import {IStETH} from "../interfaces/IStETH.sol";

import "../lib/MemUtils.sol";
import {Math64} from "../lib/Math64.sol";
import {BytesLib} from "../lib/BytesLib.sol";
import {MinFirstAllocationStrategy} from "../../common/lib/MinFirstAllocationStrategy.sol";
import {SigningKeysStats} from "../lib/SigningKeysStats.sol";

/// @title Node Operator registry implementation
///
/// See the comment of `INodeOperatorsRegistry`.
///
/// NOTE: the code below assumes moderate amount of node operators, i.e. up to `MAX_NODE_OPERATORS_COUNT`.

/// TODO: rename to CuratedValidatorsRegistry
contract NodeOperatorsRegistry is INodeOperatorsRegistry, AragonApp, IStakingModule {
    using SafeMath for uint256;
    using SafeMath64 for uint64;
    using UnstructuredStorage for bytes32;
    using SigningKeysStats for SigningKeysStats.State;

    //
    // ACL
    //
    bytes32 public constant MANAGE_SIGNING_KEYS = keccak256("MANAGE_SIGNING_KEYS");
    bytes32 public constant ADD_NODE_OPERATOR_ROLE = keccak256("ADD_NODE_OPERATOR_ROLE");
    bytes32 public constant SET_NODE_OPERATOR_NAME_ROLE = keccak256("SET_NODE_OPERATOR_NAME_ROLE");
    bytes32 public constant SET_NODE_OPERATOR_ADDRESS_ROLE = keccak256("SET_NODE_OPERATOR_ADDRESS_ROLE");
    bytes32 public constant SET_NODE_OPERATOR_LIMIT_ROLE = keccak256("SET_NODE_OPERATOR_LIMIT_ROLE");
    bytes32 public constant REQUEST_VALIDATORS_KEYS_ROLE = keccak256("REQUEST_VALIDATORS_KEYS_ROLE");
    bytes32 public constant TRIM_UNUSED_KEYS_ROLE = keccak256("TRIM_UNUSED_KEYS_ROLE");
    bytes32 public constant ACTIVATE_NODE_OPERATOR_ROLE = keccak256("ACTIVATE_NODE_OPERATOR_ROLE");
    bytes32 public constant DEACTIVATE_NODE_OPERATOR_ROLE = keccak256("DEACTIVATE_NODE_OPERATOR_ROLE");
    bytes32 public constant UPDATE_EXITED_VALIDATORS_KEYS_COUNT_ROLE = keccak256("UPDATE_EXITED_VALIDATORS_KEYS_COUNT_ROLE");
    bytes32 public constant UNSAFE_UPDATE_EXITED_VALIDATORS_KEYS_COUNT_ROLE = keccak256("UNSAFE_UPDATE_EXITED_VALIDATORS_KEYS_COUNT_ROLE");

    //
    // CONSTANTS
    //
    uint64 public constant PUBKEY_LENGTH = 48;
    uint64 public constant SIGNATURE_LENGTH = 96;
    uint256 public constant MAX_NODE_OPERATORS_COUNT = 200;
    uint256 public constant MAX_NODE_OPERATOR_NAME_LENGTH = 255;
    uint256 internal constant UINT64_MAX = uint256(uint64(-1));

    //
    // UNSTRUCTURED STORAGE POSITIONS
    //
    bytes32 internal constant SIGNING_KEYS_MAPPING_NAME = keccak256("lido.NodeOperatorsRegistry.signingKeysMappingName");

    bytes32 internal constant CONTRACT_VERSION_POSITION = keccak256("lido.NodeOperatorsRegistry.contractVersion");

    bytes32 internal constant STETH_POSITION = keccak256("lido.NodeOperatorsRegistry.stETH");

    /// @dev Total number of operators
    bytes32 internal constant TOTAL_OPERATORS_COUNT_POSITION = keccak256("lido.NodeOperatorsRegistry.totalOperatorsCount");

    /// @dev Cached number of active operators
    bytes32 internal constant ACTIVE_OPERATORS_COUNT_POSITION = keccak256("lido.NodeOperatorsRegistry.activeOperatorsCount");

    /// @dev link to the index of operations with keys
    bytes32 internal constant KEYS_OP_INDEX_POSITION = keccak256("lido.NodeOperatorsRegistry.keysOpIndex");

    /// @dev module type
    bytes32 internal constant TYPE_POSITION = keccak256("lido.NodeOperatorsRegistry.type");

    bytes32 internal constant TOTAL_SIGNING_KEYS_STATS = keccak256("lido.NodeOperatorsRegistry.totalSigningKeysStats");

    //
    // DATA TYPES
    //

    /// @dev Node Operator parameters and internal state
    struct NodeOperator {
        /// @dev Flag indicating if the operator can participate in further staking and reward distribution
        bool active;
        /// @dev Ethereum address on Execution Layer which receives steth rewards for this operator
        address rewardAddress;
        /// @dev Human-readable name
        string name;
        /// @dev Maximum number of keys for this operator to be deposited for all time
        uint64 vettedSigningKeysCount; // previously stakingLimit
        /// @dev Number of keys in the EXITED state for this operator for all time
        uint64 exitedSigningKeysCount; // previously stoppedValidators
        /// @dev Total number of keys of this operator for all time
        uint64 totalSigningKeysCount; // totalSigningKeys
        /// @dev Number of keys of this operator which were in DEPOSITED state for all time
        uint64 depositedSigningKeysCount; // usedSigningKeys
    }

    //
    // STORAGE VARIABLES
    //

    /// @dev Mapping of all node operators. Mapping is used to be able to extend the struct.
    mapping(uint256 => NodeOperator) internal _nodeOperators;

    //
    // PUBLIC & EXTERNAL METHODS
    //

    function initialize(address _steth, bytes32 _type) public onlyInit {
        // Initializations for v1 --> v2
        _initialize_v2(_steth, _type);
        initialized();
    }

    /// @notice A function to finalize upgrade to v2 (from v1). Can be called only once
    /// @dev Value 1 in CONTRACT_VERSION_POSITION is skipped due to change in numbering
    /// For more details see https://github.com/lidofinance/lido-improvement-proposals/blob/develop/LIPS/lip-10.md
    function finalizeUpgrade_v2(address _steth, bytes32 _type) external {
        require(_steth != address(0), "STETH_ADDRESS_ZERO");
        require(CONTRACT_VERSION_POSITION.getStorageUint256() == 0, "WRONG_BASE_VERSION");
        _initialize_v2(_steth, _type);
        _increaseValidatorsKeysNonce();
    }

    function _initialize_v2(address _steth, bytes32 _type) internal {
        STETH_POSITION.setStorageAddress(_steth);
        TYPE_POSITION.setStorageBytes32(_type);

        uint256 totalOperators = getNodeOperatorsCount();

        SigningKeysStats.State memory totalSigningKeysStats = _getTotalSigningKeysStats();
        for (uint256 operatorId = 0; operatorId < totalOperators; ++operatorId) {
            NodeOperator memory operator = _nodeOperators[operatorId];

            uint64 vettedSigningKeysBefore = operator.vettedSigningKeysCount;
            uint64 vettedSigningKeysAfter = Math64.min(
                operator.totalSigningKeysCount,
                Math64.max(operator.depositedSigningKeysCount, vettedSigningKeysBefore)
            );
            if (vettedSigningKeysBefore != vettedSigningKeysAfter) {
                _nodeOperators[operatorId].vettedSigningKeysCount = vettedSigningKeysAfter;
                emit VettedSigningKeysCountChanged(operatorId, vettedSigningKeysAfter);
            }
            _nodeOperators[operatorId].vettedSigningKeysCount = Math64.min(
                operator.totalSigningKeysCount,
                Math64.max(operator.depositedSigningKeysCount, operator.vettedSigningKeysCount)
            );
            totalSigningKeysStats.increaseVettedSigningKeysCount(operator.vettedSigningKeysCount);
            totalSigningKeysStats.increaseDepositedSigningKeysCount(operator.depositedSigningKeysCount);
            totalSigningKeysStats.increaseExitedSigningKeysCount(operator.exitedSigningKeysCount);
            totalSigningKeysStats.increaseTotalSigningKeysCount(operator.totalSigningKeysCount);
        }
        _setTotalSigningKeysStats(totalSigningKeysStats);

        CONTRACT_VERSION_POSITION.setStorageUint256(2);
        emit ContractVersionSet(2);
        emit StethContractSet(_steth);
        emit StakingModuleTypeSet(_type);
    }

    /// @notice Add node operator named `name` with reward address `rewardAddress` and staking limit = 0 validators
    function addNodeOperator(string _name, address _rewardAddress)
        external
        auth(ADD_NODE_OPERATOR_ROLE)
        onlyValidNodeOperatorName(_name)
        onlyNonZeroAddress(_rewardAddress)
        returns (uint256 id)
    {
        id = getNodeOperatorsCount();
        require(id < MAX_NODE_OPERATORS_COUNT, "MAX_NODE_OPERATORS_COUNT_EXCEEDED");

        TOTAL_OPERATORS_COUNT_POSITION.setStorageUint256(id + 1);

        NodeOperator storage operator = _nodeOperators[id];

        uint256 activeOperatorsCount = getActiveNodeOperatorsCount();
        ACTIVE_OPERATORS_COUNT_POSITION.setStorageUint256(activeOperatorsCount + 1);

        operator.active = true;
        operator.name = _name;
        operator.rewardAddress = _rewardAddress;

        emit NodeOperatorAdded(id, _name, _rewardAddress, 0);
    }

    // @notice Activates deactivated node operator with given id
    function activateNodeOperator(uint256 _nodeOperatorId)
        external
        onlyExistedNodeOperator(_nodeOperatorId)
        auth(ACTIVATE_NODE_OPERATOR_ROLE)
    {
        NodeOperator storage nodeOperator = _nodeOperators[_nodeOperatorId];
        require(!nodeOperator.active, "NODE_OPERATOR_ALREADY_ACTIVATED");

        uint256 activeOperatorsCount = getActiveNodeOperatorsCount();
        ACTIVE_OPERATORS_COUNT_POSITION.setStorageUint256(activeOperatorsCount.add(1));

        nodeOperator.active = true;
        _increaseValidatorsKeysNonce();

        emit NodeOperatorActivated(_nodeOperatorId);
    }

    /// @notice Deactivates active node operator with given id
    function deactivateNodeOperator(uint256 _nodeOperatorId)
        external
        onlyExistedNodeOperator(_nodeOperatorId)
        auth(DEACTIVATE_NODE_OPERATOR_ROLE)
    {
        NodeOperator storage nodeOperator = _nodeOperators[_nodeOperatorId];
        require(nodeOperator.active, "NODE_OPERATOR_ALREADY_DEACTIVATED");

        uint256 activeOperatorsCount = getActiveNodeOperatorsCount();
        ACTIVE_OPERATORS_COUNT_POSITION.setStorageUint256(activeOperatorsCount.sub(1));

        nodeOperator.active = false;
        _increaseValidatorsKeysNonce();

        emit NodeOperatorDeactivated(_nodeOperatorId);

        uint64 vettedSigningKeysCount = nodeOperator.vettedSigningKeysCount;
        uint64 depositedSigningKeysCount = nodeOperator.depositedSigningKeysCount;

        // reset approved keys count to the deposited validators count
        if (vettedSigningKeysCount > depositedSigningKeysCount) {
            nodeOperator.vettedSigningKeysCount = depositedSigningKeysCount;
            emit VettedSigningKeysCountChanged(_nodeOperatorId, depositedSigningKeysCount);

            SigningKeysStats.State memory totalValidatorStats = _getTotalSigningKeysStats();
            totalValidatorStats.decreaseVettedSigningKeysCount(vettedSigningKeysCount - depositedSigningKeysCount);
            _setTotalSigningKeysStats(totalValidatorStats);
        }
    }

    /// @notice Change human-readable name of the node operator with given id
    function setNodeOperatorName(uint256 _nodeOperatorId, string _name)
        external
        onlyExistedNodeOperator(_nodeOperatorId)
        onlyValidNodeOperatorName(_name)
        authP(SET_NODE_OPERATOR_NAME_ROLE, arr(uint256(_nodeOperatorId)))
    {
        require(keccak256(_nodeOperators[_nodeOperatorId].name) != keccak256(_name), "NODE_OPERATOR_NAME_IS_THE_SAME");
        _nodeOperators[_nodeOperatorId].name = _name;
        emit NodeOperatorNameSet(_nodeOperatorId, _name);
    }

    /// @notice Change reward address of the node operator with given id
    function setNodeOperatorRewardAddress(uint256 _nodeOperatorId, address _rewardAddress)
        external
        onlyExistedNodeOperator(_nodeOperatorId)
        onlyNonZeroAddress(_rewardAddress)
        authP(SET_NODE_OPERATOR_ADDRESS_ROLE, arr(uint256(_nodeOperatorId), uint256(_rewardAddress)))
    {
        require(_nodeOperators[_nodeOperatorId].rewardAddress != _rewardAddress, "NODE_OPERATOR_ADDRESS_IS_THE_SAME");
        _nodeOperators[_nodeOperatorId].rewardAddress = _rewardAddress;
        emit NodeOperatorRewardAddressSet(_nodeOperatorId, _rewardAddress);
    }

    /// @notice Set the maximum number of validators to stake for the node operator with given id
    /// @dev Current implementation preserves invariant: depositedSigningKeysCount <= vettedSigningKeysCount <= totalSigningKeysCount.
    ///     If _vettedSigningKeysCount out of range [depositedSigningKeysCount, totalSigningKeysCount], the new vettedSigningKeysCount
    ///     value will be set to the nearest range border.
    function setNodeOperatorStakingLimit(uint256 _nodeOperatorId, uint64 _vettedSigningKeysCount)
        external
        authP(SET_NODE_OPERATOR_LIMIT_ROLE, arr(uint256(_nodeOperatorId), uint256(_vettedSigningKeysCount)))
        onlyExistedNodeOperator(_nodeOperatorId)
    {
        NodeOperator storage nodeOperator = _nodeOperators[_nodeOperatorId];

        require(nodeOperator.active, "NODE_OPERATOR_DEACTIVATED");

        uint64 totalSigningKeysCount = nodeOperator.totalSigningKeysCount;
        uint64 depositedSigningKeysCount = nodeOperator.depositedSigningKeysCount;
        uint64 approvedValidatorsCountBefore = nodeOperator.vettedSigningKeysCount;

        uint64 approvedValidatorsCountAfter = Math64.min(
            totalSigningKeysCount,
            Math64.max(_vettedSigningKeysCount, depositedSigningKeysCount)
        );

        if (approvedValidatorsCountAfter == approvedValidatorsCountBefore) {
            return;
        }

        nodeOperator.vettedSigningKeysCount = approvedValidatorsCountAfter;

        SigningKeysStats.State memory totalValidatorKeysStats = _getTotalSigningKeysStats();
        if (approvedValidatorsCountAfter > approvedValidatorsCountBefore) {
            totalValidatorKeysStats.increaseVettedSigningKeysCount(approvedValidatorsCountAfter - approvedValidatorsCountBefore);
        } else {
            totalValidatorKeysStats.decreaseVettedSigningKeysCount(approvedValidatorsCountBefore - approvedValidatorsCountAfter);
        }
        _setTotalSigningKeysStats(totalValidatorKeysStats);
        _increaseValidatorsKeysNonce();

        emit VettedSigningKeysCountChanged(_nodeOperatorId, approvedValidatorsCountAfter);
    }

    /// @notice Updates the number of the validators in the EXITED state for node operator with given id
    function updateExitedValidatorsKeysCount(uint256 _nodeOperatorId, uint256 _exitedValidatorsKeysCount)
        external
        onlyExistedNodeOperator(_nodeOperatorId)
        auth(UPDATE_EXITED_VALIDATORS_KEYS_COUNT_ROLE)
    {
        require(_exitedValidatorsKeysCount <= UINT64_MAX, "EXITED_VALIDATORS_COUNT_TOO_LARGE");
        uint64 exitedValidatorsCountBefore = _nodeOperators[_nodeOperatorId].exitedSigningKeysCount;
        uint64 depositedSigningKeysCount = _nodeOperators[_nodeOperatorId].depositedSigningKeysCount;

        if (exitedValidatorsCountBefore == _exitedValidatorsKeysCount) {
            return;
        }

        require(_exitedValidatorsKeysCount <= depositedSigningKeysCount, "INVALID_EXITED_VALIDATORS_COUNT");
        require(_exitedValidatorsKeysCount > exitedValidatorsCountBefore, "EXITED_VALIDATORS_COUNT_DECREASED");

        _nodeOperators[_nodeOperatorId].exitedSigningKeysCount = uint64(_exitedValidatorsKeysCount);

        SigningKeysStats.State memory totalSigningKeysStats = _getTotalSigningKeysStats();
        totalSigningKeysStats.increaseExitedSigningKeysCount(uint64(_exitedValidatorsKeysCount) - exitedValidatorsCountBefore);
        _setTotalSigningKeysStats(totalSigningKeysStats);

        emit ExitedValidatorsKeysCountChanged(_nodeOperatorId, _exitedValidatorsKeysCount);
    }

    /// @notice Unsafely updates the number of the validators in the EXITED state for node operator with given id
    function unsafeUpdateExitedValidatorsKeysCount(uint256 _nodeOperatorId, uint256 _exitedValidatorsKeysCount)
        external
        onlyExistedNodeOperator(_nodeOperatorId)
        auth(UNSAFE_UPDATE_EXITED_VALIDATORS_KEYS_COUNT_ROLE)
    {
        require(_exitedValidatorsKeysCount <= UINT64_MAX, "EXITED_VALIDATORS_COUNT_TOO_LARGE");
        uint64 exitedValidatorsCountBefore = _nodeOperators[_nodeOperatorId].exitedSigningKeysCount;

        if (exitedValidatorsCountBefore == _exitedValidatorsKeysCount) {
            return;
        }

        _nodeOperators[_nodeOperatorId].exitedSigningKeysCount = uint64(_exitedValidatorsKeysCount);

        SigningKeysStats.State memory totalSigningKeysStats = _getTotalSigningKeysStats();
        if (_exitedValidatorsKeysCount > exitedValidatorsCountBefore) {
            totalSigningKeysStats.increaseExitedSigningKeysCount(uint64(_exitedValidatorsKeysCount) - exitedValidatorsCountBefore);
        } else {
            totalSigningKeysStats.decreaseExitedSigningKeysCount(exitedValidatorsCountBefore - uint64(_exitedValidatorsKeysCount));
        }
        _setTotalSigningKeysStats(totalSigningKeysStats);

        emit ExitedValidatorsKeysCountChanged(_nodeOperatorId, _exitedValidatorsKeysCount);
    }

    /// @notice Invalidates all unused validators keys for all node operators
    function invalidateReadyToDepositKeys() external auth(TRIM_UNUSED_KEYS_ROLE) {
        uint64 trimmedKeysCount = 0;
        uint64 totalTrimmedKeysCount = 0;
        uint64 approvedValidatorsDecrease = 0;
        uint256 nodeOperatorsCount = getNodeOperatorsCount();

        for (uint256 _nodeOperatorId = 0; _nodeOperatorId < nodeOperatorsCount; ++_nodeOperatorId) {
            NodeOperator storage nodeOperator = _nodeOperators[_nodeOperatorId];
            uint64 totalSigningKeysCount = nodeOperator.totalSigningKeysCount;
            uint64 vettedSigningKeysCount = nodeOperator.vettedSigningKeysCount;
            uint64 depositedSigningKeysCount = nodeOperator.depositedSigningKeysCount;

            if (depositedSigningKeysCount == totalSigningKeysCount) {
                return;
            }

            totalTrimmedKeysCount += totalSigningKeysCount - depositedSigningKeysCount;
            approvedValidatorsDecrease += vettedSigningKeysCount - depositedSigningKeysCount;

            nodeOperator.totalSigningKeysCount = depositedSigningKeysCount;
            nodeOperator.vettedSigningKeysCount = depositedSigningKeysCount;

            emit TotalValidatorsKeysCountChanged(_nodeOperatorId, depositedSigningKeysCount);
            emit VettedSigningKeysCountChanged(_nodeOperatorId, depositedSigningKeysCount);
            emit NodeOperatorUnusedValidatorsKeysTrimmed(_nodeOperatorId, trimmedKeysCount);
        }

        if (totalTrimmedKeysCount > 0) {
            SigningKeysStats.State memory totalSigningKeysStats = _getTotalSigningKeysStats();

            totalSigningKeysStats.decreaseTotalSigningKeysCount(totalTrimmedKeysCount);
            totalSigningKeysStats.decreaseVettedSigningKeysCount(approvedValidatorsDecrease);

            _setTotalSigningKeysStats(totalSigningKeysStats);
            _increaseValidatorsKeysNonce();

            emit NodeOperatorTotalKeysTrimmed(_nodeOperatorId, trimmedKeysCount);
        }
    }

    /// @notice Requests the given number of the validator keys from the staking module
    function requestValidatorsKeysForDeposits(uint256 _keysCount, bytes)
        external
        auth(REQUEST_VALIDATORS_KEYS_ROLE)
        returns (
            uint256 enqueuedValidatorsKeysCount,
            bytes memory publicKeys,
            bytes memory signatures
        )
    {
        uint256[] memory nodeOperatorIds;
        uint256[] memory activeKeysCountAfterAllocation;
        uint256[] memory exitedSigningKeysCount;
        (
            enqueuedValidatorsKeysCount,
            nodeOperatorIds,
            activeKeysCountAfterAllocation,
            exitedSigningKeysCount
        ) = _getSigningKeysAllocationData(_keysCount);

        if (enqueuedValidatorsKeysCount == 0) {
            return (0, new bytes(0), new bytes(0));
        }

        (publicKeys, signatures) = _loadAllocatedSigningKeys(
            enqueuedValidatorsKeysCount,
            nodeOperatorIds,
            activeKeysCountAfterAllocation,
            exitedSigningKeysCount
        );
        _increaseValidatorsKeysNonce();
    }

    /// @notice Returns the node operator by id
    function getNodeOperator(uint256 _nodeOperatorId, bool _fullInfo)
        external
        view
        onlyExistedNodeOperator(_nodeOperatorId)
        returns (
            bool active,
            string name,
            address rewardAddress,
            uint64 stakingLimit,
            uint64 stoppedValidators,
            uint64 totalSigningKeys,
            uint64 usedSigningKeys
        )
    {
        NodeOperator storage nodeOperator = _nodeOperators[_nodeOperatorId];

        active = nodeOperator.active;
        name = _fullInfo ? nodeOperator.name : ""; // reading name is 2+ SLOADs
        rewardAddress = nodeOperator.rewardAddress;

        stakingLimit = nodeOperator.vettedSigningKeysCount;
        stoppedValidators = nodeOperator.exitedSigningKeysCount;
        totalSigningKeys = nodeOperator.totalSigningKeysCount;
        usedSigningKeys = nodeOperator.depositedSigningKeysCount;
    }

    /// @notice Returns the rewards distribution proportional to the effective stake for each node operator.
    function getRewardsDistribution(uint256 _totalRewardShares) public view returns (address[] memory recipients, uint256[] memory shares) {
        uint256 nodeOperatorCount = getNodeOperatorsCount();

        uint256 activeCount = getActiveNodeOperatorsCount();
        recipients = new address[](activeCount);
        shares = new uint256[](activeCount);
        uint256 idx = 0;

        uint256 totalActiveValidatorsCount = 0;
        for (uint256 operatorId = 0; operatorId < nodeOperatorCount; ++operatorId) {
            NodeOperator storage nodeOperator = _nodeOperators[operatorId];
            if (!nodeOperator.active) continue;

            uint256 activeValidatorsCount = nodeOperator.depositedSigningKeysCount.sub(nodeOperator.exitedSigningKeysCount);
            totalActiveValidatorsCount = totalActiveValidatorsCount.add(activeValidatorsCount);

            recipients[idx] = nodeOperator.rewardAddress;
            shares[idx] = activeValidatorsCount;

            ++idx;
        }

        if (totalActiveValidatorsCount == 0) return (recipients, shares);

        uint256 perValidatorReward = _totalRewardShares.div(totalActiveValidatorsCount);

        for (idx = 0; idx < activeCount; ++idx) {
            shares[idx] = shares[idx].mul(perValidatorReward);
        }

        return (recipients, shares);
    }

    /// @notice Add `_quantity` validator signing keys to the keys of the node operator #`_nodeOperatorId`. Concatenated keys are: `_pubkeys`
    function addSigningKeys(
        uint256 _nodeOperatorId,
        uint256 _keysCount,
        bytes _publicKeys,
        bytes _signatures
    ) external authP(MANAGE_SIGNING_KEYS, arr(_nodeOperatorId)) {
        require(_keysCount <= UINT64_MAX, "KEYS_COUNT_TOO_LARGE");
        _addSigningKeys(_nodeOperatorId, uint64(_keysCount), _publicKeys, _signatures);
    }

    /// @notice Add `_quantity` validator signing keys of operator #`_id` to the set of usable keys. Concatenated keys are: `_pubkeys`. Can be done by node operator in question by using the designated rewards address.
    function addSigningKeysOperatorBH(
        uint256 _nodeOperatorId,
        uint256 _keysCount,
        bytes _publicKeys,
        bytes _signatures
    ) external {
        require(_keysCount <= UINT64_MAX, "KEYS_COUNT_TOO_LARGE");
        require(msg.sender == _nodeOperators[_nodeOperatorId].rewardAddress, "APP_AUTH_FAILED");
        _addSigningKeys(_nodeOperatorId, uint64(_keysCount), _publicKeys, _signatures);
    }

    /// @notice Removes a validator signing key #`_index` from the keys of the node operator #`_nodeOperatorId`
    function removeSigningKey(uint256 _nodeOperatorId, uint256 _index)
        external
        onlyExistedNodeOperator(_nodeOperatorId)
        authP(MANAGE_SIGNING_KEYS, arr(_nodeOperatorId))
    {
        require(_index <= UINT64_MAX, "INDEX_TOO_LARGE");
        _removeUnusedSigningKey(_nodeOperatorId, uint64(_index));
    }

    /// @notice Removes an #`_amount` of validator signing keys starting from #`_index` of operator #`_id` usable keys. Executed on behalf of DAO.
    function removeSigningKeys(
        uint256 _nodeOperatorId,
        uint256 _fromIndex,
        uint256 _keysCount
    ) external onlyExistedNodeOperator(_nodeOperatorId) authP(MANAGE_SIGNING_KEYS, arr(uint256(_nodeOperatorId))) {
        require(_fromIndex <= UINT64_MAX, "FROM_INDEX_TOO_LARGE");
        require(_keysCount <= UINT64_MAX, "KEYS_COUNT_TOO_LARGE");

        _removeUnusedSigningKeys(_nodeOperatorId, uint64(_fromIndex), uint64(_keysCount));
    }

    /// @notice Removes a validator signing key #`_index` of operator #`_id` from the set of usable keys. Executed on behalf of Node Operator.
    function removeSigningKeyOperatorBH(uint256 _nodeOperatorId, uint256 _index) external onlyExistedNodeOperator(_nodeOperatorId) {
        require(_index <= UINT64_MAX, "INDEX_TOO_LARGE");
        require(msg.sender == _nodeOperators[_nodeOperatorId].rewardAddress, "APP_AUTH_FAILED");
        _removeUnusedSigningKey(_nodeOperatorId, uint64(_index));
    }

    /// @notice Removes an #`_amount` of validator signing keys starting from #`_index` of operator #`_id` usable keys. Executed on behalf of Node Operator.
    function removeSigningKeysOperatorBH(
        uint256 _nodeOperatorId,
        uint256 _fromIndex,
        uint256 _keysCount
    ) external onlyExistedNodeOperator(_nodeOperatorId) {
        require(_fromIndex <= UINT64_MAX, "FROM_INDEX_TOO_LARGE");
        require(_keysCount <= UINT64_MAX, "KEYS_COUNT_TOO_LARGE");
        require(msg.sender == _nodeOperators[_nodeOperatorId].rewardAddress, "APP_AUTH_FAILED");

        _removeUnusedSigningKeys(_nodeOperatorId, uint64(_fromIndex), uint64(_keysCount));
    }

    /// @notice Returns total number of signing keys of the node operator #`_nodeOperatorId`
    function getTotalSigningKeyCount(uint256 _nodeOperatorId) external view onlyExistedNodeOperator(_nodeOperatorId) returns (uint256) {
        return _nodeOperators[_nodeOperatorId].totalSigningKeysCount;
    }

    /// @notice Returns number of usable signing keys of the node operator #`_nodeOperatorId`
    function getUnusedSigningKeyCount(uint256 _nodeOperatorId) external view onlyExistedNodeOperator(_nodeOperatorId) returns (uint256) {
        return _nodeOperators[_nodeOperatorId].totalSigningKeysCount.sub(_nodeOperators[_nodeOperatorId].depositedSigningKeysCount);
    }

    /// @notice Returns n-th signing key of the node operator #`_nodeOperatorId`
    function getSigningKey(uint256 _nodeOperatorId, uint256 _index)
        external
        view
        onlyExistedNodeOperator(_nodeOperatorId)
        returns (
            bytes key,
            bytes depositSignature,
            bool used
        )
    {
        require(_index < _nodeOperators[_nodeOperatorId].totalSigningKeysCount, "KEY_NOT_FOUND");

        (bytes memory key_, bytes memory signature) = _loadSigningKey(_nodeOperatorId, _index);

        return (key_, signature, _index < _nodeOperators[_nodeOperatorId].depositedSigningKeysCount);
    }

    /// @notice Returns a monotonically increasing counter that gets incremented when any of the following happens:
    ///   1. a node operator's key(s) is added;
    ///   2. a node operator's key(s) is removed;
    ///   3. a node operator's approved keys limit is changed.
    ///   4. a node operator was activated/deactivated. Activation or deactivation of node operator
    ///      might lead to usage of unvalidated keys in the assignNextSigningKeys method.
    function getKeysOpIndex() external view returns (uint256) {
        return KEYS_OP_INDEX_POSITION.getStorageUint256();
    }

    /// @notice Return the initialized version of this contract starting from 0
    function getVersion() external view returns (uint256) {
        return CONTRACT_VERSION_POSITION.getStorageUint256();
    }

    function getSigningKeys(
        uint256 _nodeOperatorId,
        uint256 _offset,
        uint256 _limit
    )
        external
        view
        onlyExistedNodeOperator(_nodeOperatorId)
        returns (
            bytes memory pubkeys,
            bytes memory signatures,
            bool[] memory used
        )
    {
        NodeOperator storage nodeOperator = _nodeOperators[_nodeOperatorId];
        require(_offset.add(_limit) <= nodeOperator.totalSigningKeysCount, "OUT_OF_RANGE");

        pubkeys = MemUtils.unsafeAllocateBytes(_limit.mul(PUBKEY_LENGTH));
        signatures = MemUtils.unsafeAllocateBytes(_limit.mul(SIGNATURE_LENGTH));
        used = new bool[](_limit);

        for (uint256 index = 0; index < _limit; index++) {
            (bytes memory pubkey, bytes memory signature) = _loadSigningKey(_nodeOperatorId, _offset.add(index));
            MemUtils.copyBytes(pubkey, pubkeys, index.mul(PUBKEY_LENGTH));
            MemUtils.copyBytes(signature, signatures, index.mul(SIGNATURE_LENGTH));
            used[index] = (_offset.add(index)) < nodeOperator.depositedSigningKeysCount;
        }
    }

    /// @notice Returns the type of the staking module
    function getType() external view returns (bytes32) {
        return TYPE_POSITION.getStorageBytes32();
    }

    /// @notice Returns the validators stats of all node operators in the staking module
    function getValidatorsKeysStats()
        external
        view
        returns (
            uint256 exitedValidatorsCount,
            uint256 activeValidatorsKeysCount,
            uint256 readyToDepositValidatorsKeysCount
        )
    {
        SigningKeysStats.State memory totalSigningKeysStats = _getTotalSigningKeysStats();

        uint256 vettedSigningKeysCount = totalSigningKeysStats.vettedSigningKeysCount;
        uint256 depositedSigningKeysCount = totalSigningKeysStats.depositedSigningKeysCount;

        exitedValidatorsCount = totalSigningKeysStats.exitedSigningKeysCount;
        activeValidatorsKeysCount = depositedSigningKeysCount - exitedValidatorsCount;
        readyToDepositValidatorsKeysCount = vettedSigningKeysCount - depositedSigningKeysCount;
    }

    /// @notice Returns the validators stats of given node operator
    function getValidatorsKeysStats(uint256 _nodeOperatorId)
        public
        view
        returns (
            uint256 exitedValidatorsCount,
            uint256 activeValidatorsKeysCount,
            uint256 readyToDepositValidatorsKeysCount
        )
    {
        NodeOperator storage nodeOperator = _nodeOperators[_nodeOperatorId];

        uint256 vettedSigningKeysCount = nodeOperator.vettedSigningKeysCount;
        uint256 depositedSigningKeysCount = nodeOperator.depositedSigningKeysCount;

        exitedValidatorsCount = nodeOperator.exitedSigningKeysCount;
        activeValidatorsKeysCount = depositedSigningKeysCount - exitedValidatorsCount;
        readyToDepositValidatorsKeysCount = vettedSigningKeysCount - depositedSigningKeysCount;
    }

    /// @notice Returns total number of node operators
    function getNodeOperatorsCount() public view returns (uint256) {
        return TOTAL_OPERATORS_COUNT_POSITION.getStorageUint256();
    }

    /// @notice Returns number of active node operators
    function getActiveNodeOperatorsCount() public view returns (uint256) {
        return ACTIVE_OPERATORS_COUNT_POSITION.getStorageUint256();
    }

    /// @notice Returns if the node operator with given id is active
    function getNodeOperatorIsActive(uint256 _nodeOperatorId) external view returns (bool) {
        return _nodeOperators[_nodeOperatorId].active;
    }

    /// @notice Returns a counter that MUST change it's value when any of the following happens:
    ///     1. a node operator's key(s) is added
    ///     2. a node operator's key(s) is removed
    ///     3. a node operator's ready to deposit keys count is changed
    ///     4. a node operator was activated/deactivated
    function getValidatorsKeysNonce() external view returns (uint256) {
        return KEYS_OP_INDEX_POSITION.getStorageUint256();
    }

    /// @notice distributes rewards among node operators
    /// @return distributed Amount of stETH shares distributed among node operators
    function distributeRewards() external returns (uint256 distributed) {
        IStETH stETH = IStETH(STETH_POSITION.getStorageAddress());

        uint256 sharesToDistribute = stETH.sharesOf(address(this));
        assert(sharesToDistribute > 0);

        (address[] memory recipients, uint256[] memory shares) = getRewardsDistribution(sharesToDistribute);

        assert(recipients.length == shares.length);

        distributed = 0;
        for (uint256 idx = 0; idx < recipients.length; ++idx) {
            stETH.transferShares(recipients[idx], shares[idx]);
            distributed = distributed.add(shares[idx]);
            emit RewardsDistributedInShares(idx, shares[idx]);
        }
    }

    //
    // INTERNAL METHODS
    //

    function _getSigningKeysAllocationData(uint256 _keysCount)
        internal
        view
        returns (
            uint256 allocatedKeysCount,
            uint256[] memory nodeOperatorIds,
            uint256[] memory activeKeysCounts,
            uint256[] memory exitedSigningKeysCount
        )
    {
        uint256 activeNodeOperatorsCount = getActiveNodeOperatorsCount();
        nodeOperatorIds = new uint256[](activeNodeOperatorsCount);
        activeKeysCounts = new uint256[](activeNodeOperatorsCount);
        exitedSigningKeysCount = new uint256[](activeNodeOperatorsCount);
        uint256[] memory activeKeysCapacities = new uint256[](activeNodeOperatorsCount);

        uint256 activeNodeOperatorIndex;
        uint256 nodeOperatorsCount = getNodeOperatorsCount();
        for (uint256 nodeOperatorId = 0; nodeOperatorId < nodeOperatorsCount; ++nodeOperatorId) {
            NodeOperator storage nodeOperator = _nodeOperators[nodeOperatorId];
            if (!nodeOperator.active) continue;

            nodeOperatorIds[activeNodeOperatorIndex] = nodeOperatorId;
            exitedSigningKeysCount[activeNodeOperatorIndex] = nodeOperator.exitedSigningKeysCount;
            uint256 depositedSigningKeysCount = nodeOperator.depositedSigningKeysCount;
            uint256 vettedSigningKeysCount = nodeOperator.vettedSigningKeysCount;

            activeKeysCounts[activeNodeOperatorIndex] = depositedSigningKeysCount.sub(exitedSigningKeysCount[activeNodeOperatorIndex]);
            activeKeysCapacities[activeNodeOperatorIndex] = vettedSigningKeysCount.sub(exitedSigningKeysCount[activeNodeOperatorIndex]);

            ++activeNodeOperatorIndex;
        }

        allocatedKeysCount = MinFirstAllocationStrategy.allocate(activeKeysCounts, activeKeysCapacities, _keysCount);

        assert(allocatedKeysCount <= _keysCount);
    }

    function _loadAllocatedSigningKeys(
        uint256 _keysCountToLoad,
        uint256[] memory _nodeOperatorIds,
        uint256[] memory _keysCountAfterAllocation,
        uint256[] memory _exitedSigningKeysCount
    ) internal returns (bytes memory publicKeys, bytes memory signatures) {
        publicKeys = MemUtils.unsafeAllocateBytes(_keysCountToLoad * PUBKEY_LENGTH);
        signatures = MemUtils.unsafeAllocateBytes(_keysCountToLoad * SIGNATURE_LENGTH);

        uint256 loadedKeysCount = 0;
        for (uint256 i = 0; i < _nodeOperatorIds.length; ++i) {
            NodeOperator storage nodeOperator = _nodeOperators[_nodeOperatorIds[i]];

            uint64 depositedSigningKeysCountBefore = nodeOperator.depositedSigningKeysCount;
            uint64 depositedSigningKeysCountAfter = uint64(_exitedSigningKeysCount[i].add(_keysCountAfterAllocation[i]));

            for (uint256 keyIndex = depositedSigningKeysCountBefore; keyIndex < depositedSigningKeysCountAfter; ++keyIndex) {
                (bytes memory pubkey, bytes memory signature) = _loadSigningKey(_nodeOperatorIds[i], keyIndex);
                MemUtils.copyBytes(pubkey, publicKeys, loadedKeysCount * PUBKEY_LENGTH);
                MemUtils.copyBytes(signature, signatures, loadedKeysCount * SIGNATURE_LENGTH);
                ++loadedKeysCount;
            }
            nodeOperator.depositedSigningKeysCount = depositedSigningKeysCountAfter;
        }

        assert(loadedKeysCount == _keysCountToLoad);
    }

    function _isEmptySigningKey(bytes memory _key) internal pure returns (bool) {
        assert(_key.length == PUBKEY_LENGTH);

        uint256 k1;
        uint256 k2;
        assembly {
            k1 := mload(add(_key, 0x20))
            k2 := mload(add(_key, 0x40))
        }

        return 0 == k1 && 0 == (k2 >> ((2 * 32 - PUBKEY_LENGTH) * 8));
    }

    function _signingKeyOffset(uint256 _nodeOperatorId, uint256 _keyIndex) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(SIGNING_KEYS_MAPPING_NAME, _nodeOperatorId, _keyIndex)));
    }

    function _storeSigningKey(
        uint256 _nodeOperatorId,
        uint256 _keyIndex,
        bytes memory _key,
        bytes memory _signature
    ) internal {
        assert(_key.length == PUBKEY_LENGTH);
        assert(_signature.length == SIGNATURE_LENGTH);

        // key
        uint256 offset = _signingKeyOffset(_nodeOperatorId, _keyIndex);
        uint256 keyExcessBits = (2 * 32 - PUBKEY_LENGTH) * 8;
        assembly {
            sstore(offset, mload(add(_key, 0x20)))
            sstore(add(offset, 1), shl(keyExcessBits, shr(keyExcessBits, mload(add(_key, 0x40)))))
        }
        offset += 2;

        // signature
        for (uint256 i = 0; i < SIGNATURE_LENGTH; i += 32) {
            assembly {
                sstore(offset, mload(add(_signature, add(0x20, i))))
            }
            offset++;
        }
    }

    function _addSigningKeys(
        uint256 _nodeOperatorId,
        uint64 _keysCount,
        bytes _publicKeys,
        bytes _signatures
    ) internal onlyExistedNodeOperator(_nodeOperatorId) {
        require(_keysCount != 0, "NO_KEYS");
        require(_publicKeys.length == _keysCount.mul(PUBKEY_LENGTH), "INVALID_LENGTH");
        require(_signatures.length == _keysCount.mul(SIGNATURE_LENGTH), "INVALID_LENGTH");

        _increaseValidatorsKeysNonce();

        NodeOperator storage nodeOperator = _nodeOperators[_nodeOperatorId];
        uint64 totalSigningKeysCount = nodeOperator.totalSigningKeysCount;
        for (uint256 i = 0; i < _keysCount; ++i) {
            bytes memory key = BytesLib.slice(_publicKeys, i * PUBKEY_LENGTH, PUBKEY_LENGTH);
            require(!_isEmptySigningKey(key), "EMPTY_KEY");
            bytes memory sig = BytesLib.slice(_signatures, i * SIGNATURE_LENGTH, SIGNATURE_LENGTH);

            _storeSigningKey(_nodeOperatorId, totalSigningKeysCount, key, sig);
            totalSigningKeysCount += 1;
            emit SigningKeyAdded(_nodeOperatorId, key);
        }

        emit TotalValidatorsKeysCountChanged(_nodeOperatorId, totalSigningKeysCount);

        _nodeOperators[_nodeOperatorId].totalSigningKeysCount = totalSigningKeysCount;

        SigningKeysStats.State memory totalSigningKeysStats = _getTotalSigningKeysStats();
        totalSigningKeysStats.increaseTotalSigningKeysCount(_keysCount);
        _setTotalSigningKeysStats(totalSigningKeysStats);
    }

    function _removeUnusedSigningKeys(
        uint256 _nodeOperatorId,
        uint64 _fromIndex,
        uint64 _keysCount
    ) internal {
        NodeOperator storage nodeOperator = _nodeOperators[_nodeOperatorId];

        uint64 approveValidatorsCountBefore = nodeOperator.vettedSigningKeysCount;

        // removing from the last index to the highest one, so we won't get outside the array
        for (uint64 i = _fromIndex.add(_keysCount); i > _fromIndex; --i) {
            _removeUnusedSigningKey(_nodeOperatorId, i - 1);
        }

        _increaseValidatorsKeysNonce();

        uint64 totalValidatorsCountAfter = nodeOperator.totalSigningKeysCount;
        uint64 approvedValidatorsCountAfter = nodeOperator.vettedSigningKeysCount;

        emit TotalValidatorsKeysCountChanged(_nodeOperatorId, totalValidatorsCountAfter);
        emit VettedSigningKeysCountChanged(_nodeOperatorId, approvedValidatorsCountAfter);

        SigningKeysStats.State memory totalSigningKeysStats = _getTotalSigningKeysStats();
        totalSigningKeysStats.decreaseTotalSigningKeysCount(_keysCount);

        if (approveValidatorsCountBefore > approvedValidatorsCountAfter) {
            totalSigningKeysStats.decreaseVettedSigningKeysCount(approveValidatorsCountBefore - approvedValidatorsCountAfter);
        }

        _setTotalSigningKeysStats(totalSigningKeysStats);
    }

    function _removeUnusedSigningKey(uint256 _nodeOperatorId, uint64 _index) internal {
        NodeOperator storage nodeOperator = _nodeOperators[_nodeOperatorId];

        uint64 totalSigningKeysCount = nodeOperator.totalSigningKeysCount;
        require(_index < totalSigningKeysCount, "KEY_NOT_FOUND");

        uint64 depositedSigningKeysCount = nodeOperator.depositedSigningKeysCount;
        require(_index >= depositedSigningKeysCount, "KEY_WAS_USED");

        uint64 lastValidatorKeyIndex = totalSigningKeysCount.sub(1);
        uint64 vettedSigningKeysCount = nodeOperator.vettedSigningKeysCount;

        (bytes memory removedKey, ) = _loadSigningKey(_nodeOperatorId, _index);

        if (_index < lastValidatorKeyIndex) {
            (bytes memory key, bytes memory signature) = _loadSigningKey(_nodeOperatorId, lastValidatorKeyIndex);
            _storeSigningKey(_nodeOperatorId, _index, key, signature);
        }

        _deleteSigningKey(_nodeOperatorId, lastValidatorKeyIndex);

        nodeOperator.totalSigningKeysCount = totalSigningKeysCount.sub(1);
        emit TotalValidatorsKeysCountChanged(_nodeOperatorId, _index);

        if (_index < vettedSigningKeysCount) {
            // decreasing the staking limit so the key at _index can't be used anymore
            nodeOperator.vettedSigningKeysCount = _index;
            emit VettedSigningKeysCountChanged(_nodeOperatorId, _index);
        }

        emit SigningKeyRemoved(_nodeOperatorId, removedKey);
    }

    function _deleteSigningKey(uint256 _nodeOperatorId, uint256 _keyIndex) internal {
        uint256 offset = _signingKeyOffset(_nodeOperatorId, _keyIndex);
        for (uint256 i = 0; i < (PUBKEY_LENGTH + SIGNATURE_LENGTH) / 32 + 1; ++i) {
            assembly {
                sstore(add(offset, i), 0)
            }
        }
    }

    function _loadSigningKey(uint256 _nodeOperatorId, uint256 _keyIndex) internal view returns (bytes memory key, bytes memory signature) {
        uint256 offset = _signingKeyOffset(_nodeOperatorId, _keyIndex);

        // key
        bytes memory tmpKey = new bytes(64);
        assembly {
            mstore(add(tmpKey, 0x20), sload(offset))
            mstore(add(tmpKey, 0x40), sload(add(offset, 1)))
        }
        offset += 2;
        key = BytesLib.slice(tmpKey, 0, PUBKEY_LENGTH);

        // signature
        signature = new bytes(SIGNATURE_LENGTH);
        for (uint256 i = 0; i < SIGNATURE_LENGTH; i += 32) {
            assembly {
                mstore(add(signature, add(0x20, i)), sload(offset))
            }
            offset++;
        }

        return (key, signature);
    }

    function _increaseValidatorsKeysNonce() internal {
        uint256 keysOpIndex = KEYS_OP_INDEX_POSITION.getStorageUint256() + 1;
        KEYS_OP_INDEX_POSITION.setStorageUint256(keysOpIndex);
        emit KeysOpIndexSet(keysOpIndex);
    }

    function _setTotalSigningKeysStats(SigningKeysStats.State memory _validatorsKeysStats) internal {
        _validatorsKeysStats.store(TOTAL_SIGNING_KEYS_STATS);
    }

    function _getTotalSigningKeysStats() internal view returns (SigningKeysStats.State memory) {
        return SigningKeysStats.load(TOTAL_SIGNING_KEYS_STATS);
    }

    //
    // MODIFIERS
    //

    modifier onlyNonZeroAddress(address _a) {
        require(_a != address(0), "ZERO_ADDRESS");
        _;
    }

    modifier onlyExistedNodeOperator(uint256 _nodeOperatorId) {
        require(_nodeOperatorId < getNodeOperatorsCount(), "NODE_OPERATOR_NOT_FOUND");
        _;
    }

    modifier onlyValidNodeOperatorName(string _name) {
        require(bytes(_name).length > 0, "NAME_IS_EMPTY");
        require(bytes(_name).length <= MAX_NODE_OPERATOR_NAME_LENGTH, "NAME_TOO_LONG");
        _;
    }
}
