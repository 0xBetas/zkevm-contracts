// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.8.20;

import "./interfaces/IPolygonRollupManager.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../interfaces/IPolygonZkEVMGlobalExitRoot.sol";
import "../interfaces/IPolygonZkEVMBridge.sol";
import "./interfaces/IPolygonRollupBase.sol";
import "../lib/EmergencyManager.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "./lib/PolygonAccessControlUpgradeable.sol";
import "../interfaces/IVerifierRollup.sol";
import "./consensus/zkEVM/PolygonZkEVMV2Upgraded.sol";

// TODO change name to network, networkID consistent
// TODO check contract slots!

/**
 * Contract responsible for managing the exit roots across multiple Rollups
 */
contract PolygonRollupManager is
    PolygonAccessControlUpgradeable,
    EmergencyManager,
    IPolygonRollupManager
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /**
     * @notice Struct which will be stored for every batch sequence
     * @param accInputHash Hash chain that contains all the information to process a batch:
     *  keccak256(bytes32 oldAccInputHash, keccak256(bytes transactions), bytes32 globalExitRoot, uint64 timestamp, address seqAddress)
     * @param sequencedTimestamp Sequenced timestamp
     * @param previousLastBatchSequenced Previous last batch sequenced before the current one, this is used to properly calculate the fees
     */
    struct SequencedBatchData {
        bytes32 accInputHash;
        uint64 sequencedTimestamp;
        uint64 previousLastBatchSequenced;
    }

    /**
     * @notice Struct which to store the rollup type data
     * @param consensusImplementation Consensus implementation ( contains the consensus logic for the transaparent proxy)
     * @param verifier verifier
     * @param forkID fork ID
     * @param rollupCompatibilityID Rollup compatibility ID, to check upgradability between rollup types
     * @param genesis Genesis block of the rollup, note that will only be used on creating new rollups, not upgrade them
     * @param description Previous last batch sequenced before the current one, this is used to properly calculate the fees
     */
    struct RollupType {
        address consensusImplementation;
        IVerifierRollup verifier;
        uint64 forkID;
        uint8 rollupCompatibilityID;
        bool obsolete;
        bytes32 genesis;
        string description;
    }

    /**
     * @notice Struct which to store the rollup data of each chain
     * @param accInputHash Hash chain that contains all the information to process a batch:
     *  keccak256(bytes32 oldAccInputHash, keccak256(bytes transactions), bytes32 globalExitRoot, uint64 timestamp, address seqAddress)
     * @param sequencedTimestamp Sequenced timestamp
     * @param previousLastBatchSequenced Previous last batch sequenced before the current one, this is used to properly calculate the fees
     */
    struct RollupData {
        IPolygonRollupBase rollupContract;
        uint64 chainID;
        IVerifierRollup verifier;
        uint64 forkID;
        mapping(uint64 => bytes32) batchNumToStateRoot;
        mapping(uint64 => SequencedBatchData) sequencedBatches;
        mapping(uint256 => PendingState) pendingStateTransitions;
        bytes32 lastLocalExitRoot;
        uint64 lastBatchSequenced;
        uint64 lastVerifiedBatch;
        uint64 lastPendingState;
        uint64 lastPendingStateConsolidated;
        uint64 lastVerifiedBatchBeforeUpgrade; // TODO ADD CHECK when verify
        uint64 rollupTypeID;
        uint8 rollupCompatibilityID;
    }

    /**
     * @notice Struct to store the pending states
     * Pending state will be an intermediary state, that after a timeout can be consolidated, which means that will be added
     * to the state root mapping, and the global exit root will be updated
     * This is a protection mechanism against soundness attacks, that will be turned off in the future
     * @param timestamp Timestamp where the pending state is added to the queue
     * @param lastVerifiedBatch Last batch verified batch of this pending state
     * @param exitRoot Pending exit root
     * @param stateRoot Pending state root
     */
    struct PendingState {
        uint64 timestamp;
        uint64 lastVerifiedBatch;
        bytes32 exitRoot;
        bytes32 stateRoot;
    }

    // Modulus zkSNARK
    uint256 internal constant _RFIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    // If a sequenced batch exceeds this timeout without being verified, the contract enters in emergency mode
    uint64 internal constant _HALT_AGGREGATION_TIMEOUT = 1 weeks;

    // Maximum batches that can be verified in one call. It depends on our current metrics
    // This should be a protection against someone that tries to generate huge chunk of invalid batches, and we can't prove otherwise before the pending timeout expires
    uint64 internal constant _MAX_VERIFY_BATCHES = 1000;

    // Max batch multiplier per verification
    uint256 internal constant _MAX_BATCH_MULTIPLIER = 12;

    // Max batch fee value
    uint256 internal constant _MAX_BATCH_FEE = 1000 ether;

    // Min value batch fee
    uint256 internal constant _MIN_BATCH_FEE = 1 gwei;

    // Goldilocks prime field
    uint256 internal constant _GOLDILOCKS_PRIME_FIELD = 0xFFFFFFFF00000001; // 2 ** 64 - 2 ** 32 + 1

    // Max uint64
    uint256 internal constant _MAX_UINT_64 = type(uint64).max; // 0xFFFFFFFFFFFFFFFF

    // Exit merkle tree levels
    uint256 internal constant _EXIT_TREE_DEPTH = 32;

    // L2 chain identifier
    uint64 internal constant _ZKEVM_CHAINID = 1101;

    // zkEVM FORK ID
    uint64 internal immutable _ZKEVM_FORKID = 5;

    // Existing roles on rollup manager

    // Trusted aggregator will be able to verify batches without extra delau
    bytes32 internal constant _ADD_ROLLUP_TYPE_ROLE =
        keccak256("ADD_ROLLUP_TYPE_ROLE");

    // Trusted aggregator will be able to verify batches without extra delau
    bytes32 internal constant _DELETE_ROLLUP_TYPE_ROLE =
        keccak256("DELETE_ROLLUP_TYPE_ROLE");

    bytes32 internal constant _CREATE_ROLLUP_ROLE =
        keccak256("CREATE_ROLLUP_ROLE");

    bytes32 internal constant _ADD_EXISTING_ROLLUP_ROLE =
        keccak256("ADD_EXISTING_ROLLUP_ROLE");

    bytes32 internal constant _UPDATE_ROLLUP_ROLE =
        keccak256("UPDATE_ROLLUP_ROLE");

    // Trusted aggregator will be able to verify batches without extra delau
    bytes32 internal constant _TRUSTED_AGGREGATOR_ROLE =
        keccak256("TRUSTED_AGGREGATOR_ROLE");

    bytes32 internal constant _TWEAK_PARAMETERS_ROLE =
        keccak256("TWEAK_PARAMETERS_ROLE");

    // Will be able to set the current batch fee
    bytes32 internal constant _SET_FEE_ROLE = keccak256("SET_FEE_ROLE");

    bytes32 internal constant _STOP_EMERGENCY_ROLE =
        keccak256("STOP_EMERGENCY_ROLE");

    // Trusted aggregator will be able to verify batches without extra delau
    bytes32 internal constant _EMERGENCY_COUNCIL_ROLE =
        keccak256("EMERGENCY_COUNCIL_ROLE");

    // Will be able to update the emergency council
    bytes32 internal constant _EMERGENCY_COUNCIL_ADMIN =
        keccak256("EMERGENCY_COUNCIL_ADMIN");

    // Global Exit Root interface
    IPolygonZkEVMGlobalExitRoot public immutable globalExitRootManager;

    // PolygonZkEVM Bridge Address
    IPolygonZkEVMBridge public immutable bridgeAddress;

    // MATIC token address
    IERC20Upgradeable public immutable matic;

    // since this contract will be an update of the PolygonZkEVM there are legacy variables
    // This ones would not be used generally,just for reserve the same storage slots, since
    // this contract will be

    // Time target of the verification of a batch
    // Adaptatly the batchFee will be updated to achieve this target
    uint64 internal _legacyVerifyBatchTimeTarget;

    // Batch fee multiplier with 3 decimals that goes from 1000 - 1023
    uint16 internal _legacyMultiplierBatchFee;

    // Trusted sequencer address
    address internal _legacyTrustedSequencer;

    // Current matic fee per batch sequenced
    uint256 internal _legacyBatchFee;

    // Queue of forced batches with their associated data
    // ForceBatchNum --> hashedForcedBatchData
    // hashedForcedBatchData: hash containing the necessary information to force a batch:
    // keccak256(keccak256(bytes transactions), bytes32 globalExitRoot, unint64 minForcedTimestamp)
    mapping(uint64 => bytes32) internal _legacyForcedBatches;

    // Queue of batches that defines the virtual state
    // SequenceBatchNum --> SequencedBatchData
    mapping(uint64 => SequencedBatchData) internal _legacySequencedBatches;

    // Last sequenced timestamp
    uint64 internal _legacyLastTimestamp;

    // Last batch sent by the sequencers
    uint64 internal _legacylastBatchSequenced;

    // Last forced batch included in the sequence
    uint64 internal _legacyLastForceBatchSequenced;

    // Last forced batch
    uint64 internal _legacyLastForceBatch;

    // Last batch verified by the aggregators
    uint64 internal _legacyLastVerifiedBatch;

    // Trusted aggregator address
    address internal _legacyTrustedAggregator;

    // State root mapping
    // BatchNum --> state root
    mapping(uint64 => bytes32) internal _legacyBatchNumToStateRoot;

    // Trusted sequencer URL
    string internal _legacyTrustedSequencerURL;

    // L2 network name
    string internal _legacyNetworkName;

    // Pending state mapping
    // pendingStateNumber --> PendingState
    mapping(uint256 => PendingState) internal _legacyPendingStateTransitions;

    // Last pending state
    uint64 internal _legacyLastPendingState;

    // Last pending state consolidated
    uint64 internal _legacyLastPendingStateConsolidated;

    // Once a pending state exceeds this timeout it can be consolidated
    uint64 internal _legacyPendingStateTimeout;

    // Trusted aggregator timeout, if a sequence is not verified in this time frame,
    // everyone can verify that sequence
    uint64 internal _legacyTrustedAggregatorTimeout;

    // Address that will be able to adjust contract parameters or stop the emergency state
    address internal _legacyAdmin;

    // This account will be able to accept the admin role
    address internal _legacyPendingAdmin;

    // Force batch timeout
    uint64 internal _legacyForceBatchTimeout;

    // Indicates if forced batches are disallowed
    bool internal _legacyIsForcedBatchDisallowed;

    // Indicates the current version
    uint256 internal _legacyVersion;

    // Last batch verified before the last upgrade
    uint256 internal _legacyLastVerifiedBatchBeforeUpgrade;

    // Number of rollup types added, every new consensus will be assigned sequencially a new ID
    uint32 public rollupTypeCount;

    // Consensus mapping
    mapping(uint64 rollupTypeID => RollupType) public rollupTypeMap;

    // Rollup Count
    uint32 public rollupCount;

    // Rollups mapping
    mapping(uint32 rollupID => RollupData) public rollupIDToRollupData;

    // Rollups mapping
    // RollupAddress => rollupID
    mapping(address rollupAddress => uint32 rollupID) public rollupAddressToID;

    // Rollups mapping
    // chainID => rollupID
    mapping(uint64 chainID => uint32 rollupID) public chainIDToRollupID;

    // Once a pending state exceeds this timeout it can be consolidated
    uint64 public pendingStateTimeout;

    // Trusted aggregator timeout, if a sequence is not verified in this time frame,
    // everyone can verify that sequence
    uint64 public trustedAggregatorTimeout;

    // Total sequenced batches between all rollups
    uint64 public totalSequencedBatches;

    // Total pending batches between all networks
    uint64 public totalPendingForcedBatches;

    // Total verified batches between all rollups
    uint64 public totalVerifiedBatches;

    // Last timestamp where an aggregation happen
    uint64 public lastAggregationTimestamp;

    // Time target of the verification of a batch
    // Adaptatly the batchFee will be updated to achieve this target
    uint64 public verifyBatchTimeTarget;

    // Batch fee multiplier with 3 decimals that goes from 1000 - 1023
    uint16 public multiplierBatchFee;

    // Current matic fee per batch sequenced
    uint256 public batchFee;

    // Address that has priority to verify batches, also enables bridges instantly
    address public trustedAggregator;

    /**
     * @dev Emitted when a new rollup type is added
     */
    event AddNewRollupType(
        uint32 rollupTypeID,
        address consensusImplementation,
        address verifier,
        uint64 forkID,
        bytes32 genesis,
        string description
    );

    /**
     * @dev Emitted when a a rolup type is deleted
     */
    event DeleteRollupType(uint32 rollupTypeID);

    /**
     * @dev Emitted when a new rollup is created based on a rollupType
     */
    event CreateNewRollup(
        uint32 rollupID,
        uint32 rollupTypeID,
        address rollupAddress,
        uint64 chainID
    );

    /**
     * @dev Emitted when an existing rollup is added
     */
    event AddExistingRollup(
        uint32 rollupID,
        uint64 forkID,
        address rollupAddress,
        uint64 chainID,
        uint8 rollupCompatibilityID
    );

    /**
     * @dev Emitted when a rollup is udpated
     */
    event UpdateRollup(
        uint32 rollupID,
        uint32 newRollupTypeID,
        uint64 lastVerifiedBatchBeforeUpgrade
    );

    /**
     * @dev Emitted when a new verifier is added
     */
    event OnSequenceBatches(uint32 rollupID, uint64 lastBatchSequenced);

    /**
     * @dev Emitted when a aggregator verifies batches
     */
    event VerifyBatches(
        uint32 rollupID,
        uint64 indexed numBatch,
        bytes32 stateRoot,
        address indexed aggregator
    );

    /**
     * @dev Emitted when a aggregator verifies batches
     */
    event VerifyBatchesTrustedAggregator(
        uint32 rollupID,
        uint64 indexed numBatch,
        bytes32 stateRoot,
        address indexed aggregator
    );

    /**
     * @dev Emitted when pending state is consolidated
     */
    event ConsolidatePendingState(
        uint32 rollupID,
        uint64 indexed numBatch,
        bytes32 stateRoot,
        uint64 indexed pendingStateNum
    );

    /**
     * @dev Emitted when is proved a different state given the same batches
     */
    event ProveNonDeterministicPendingState(
        bytes32 storedStateRoot,
        bytes32 provedStateRoot
    );

    /**
     * @dev Emitted when the trusted aggregator overrides pending state
     */
    event OverridePendingState(
        uint64 indexed numBatch,
        bytes32 stateRoot,
        address indexed aggregator
    );

    /**
     * @dev Emitted when the admin updates the trusted aggregator timeout
     */
    event SetTrustedAggregatorTimeout(uint64 newTrustedAggregatorTimeout);

    /**
     * @dev Emitted when the admin updates the pending state timeout
     */
    event SetPendingStateTimeout(uint64 newPendingStateTimeout);

    /**
     * @dev Emitted when the admin updates the multiplier batch fee
     */
    event SetMultiplierBatchFee(uint16 newMultiplierBatchFee);

    /**
     * @dev Emitted when the admin updates the verify batch timeout
     */
    event SetVerifyBatchTimeTarget(uint64 newVerifyBatchTimeTarget);

    /**
     * @dev Emitted when the admin updates the trusted aggregator address
     */
    event SetTrustedAggregator(address newTrustedAggregator);

    /**
     * @dev Emitted when the batch fee is set
     */
    event SetBatchFee(uint256 newBatchFee);

    /**
     * @param _globalExitRootManager Global exit root manager address
     * @param _matic MATIC token address
     * @param _bridgeAddress Bridge address
     */
    constructor(
        IPolygonZkEVMGlobalExitRoot _globalExitRootManager,
        IERC20Upgradeable _matic,
        IPolygonZkEVMBridge _bridgeAddress
    ) {
        globalExitRootManager = _globalExitRootManager;
        matic = _matic;
        bridgeAddress = _bridgeAddress;
    }

    // TODO Add array fo consensus and verifiers and deploy zkEVM with legacy information
    function initialize(
        address _trustedAggregator,
        uint64 _pendingStateTimeout,
        uint64 _trustedAggregatorTimeout,
        address admin,
        address timelock,
        address emergencyCouncil,
        PolygonZkEVMV2Upgraded polygonZkEVM,
        IVerifierRollup zkEVMVerifier
    ) external initializer {
        trustedAggregator = _trustedAggregator;
        pendingStateTimeout = _pendingStateTimeout;
        trustedAggregatorTimeout = _trustedAggregatorTimeout;

        // Initialize OZ contracts
        __AccessControl_init();

        // setup roles

        // Timelock roles
        _setupRole(DEFAULT_ADMIN_ROLE, timelock);
        _setupRole(_ADD_ROLLUP_TYPE_ROLE, timelock);
        _setupRole(_ADD_EXISTING_ROLLUP_ROLE, timelock);
        // role fees
        // role rest of parameters

        // Even this role can only update to an already added verifier/consensus
        // Could break the compatibility of them, changing the virtual state
        // review
        _setupRole(_UPDATE_ROLLUP_ROLE, timelock);

        // Admin roles
        _setupRole(_DELETE_ROLLUP_TYPE_ROLE, admin);
        _setupRole(_CREATE_ROLLUP_ROLE, admin);
        _setupRole(_STOP_EMERGENCY_ROLE, admin);
        _setupRole(_TRUSTED_AGGREGATOR_ROLE, admin);
        _setupRole(_TWEAK_PARAMETERS_ROLE, admin);

        // review Could be another address?¿
        _setupRole(_SET_FEE_ROLE, admin);

        // Emergency council roles
        _setupRole(_EMERGENCY_COUNCIL_ROLE, emergencyCouncil);
        _setupRole(_EMERGENCY_COUNCIL_ADMIN, emergencyCouncil);

        // Initialize current zkEVM
        RollupData storage currentZkEVM = _addExistingRollup(
            IPolygonRollupBase(polygonZkEVM),
            zkEVMVerifier,
            _ZKEVM_FORKID,
            _ZKEVM_CHAINID,
            0 // Rollup compatibility ID is 0
        );

        uint64 zkEVMLastBatchSequenced = _legacylastBatchSequenced;
        uint64 zkEVMLastVerifiedBatch = _legacyLastVerifiedBatch;
        if (zkEVMLastBatchSequenced != zkEVMLastVerifiedBatch) {
            revert();
        }

        // Copy variables from legacy
        currentZkEVM.batchNumToStateRoot[
            zkEVMLastVerifiedBatch
        ] = _legacyBatchNumToStateRoot[zkEVMLastVerifiedBatch];

        currentZkEVM.sequencedBatches[
            zkEVMLastBatchSequenced
        ] = _legacySequencedBatches[zkEVMLastBatchSequenced];

        currentZkEVM.lastBatchSequenced = zkEVMLastBatchSequenced;
        currentZkEVM.lastVerifiedBatch = zkEVMLastVerifiedBatch;
        currentZkEVM.lastVerifiedBatchBeforeUpgrade = zkEVMLastVerifiedBatch;
        // rollupType and rollupCompatibilityID will be both 0

        // Initialize polygon zkevm
        polygonZkEVM.initializeUpgrade(
            _legacyAdmin,
            _legacyTrustedSequencer,
            _legacyTrustedSequencerURL,
            _legacyNetworkName,
            _legacySequencedBatches[zkEVMLastBatchSequenced].accInputHash,
            _legacyLastTimestamp
        );
    }

    ////////////////////////////////////////////////
    // Rollups management functions
    ///////////////////////////////////////////////

    /**
     * @notice Add a new zkEVM type
     * @param consensusImplementation new consensus implementation
     * @param verifier new verifier address
     * @param forkID forkID of the verifier
     * @param genesis genesis block of the zkEVM
     * @param description description of the zkEVM type
     */
    function addNewRollupType(
        address consensusImplementation,
        IVerifierRollup verifier,
        uint64 forkID,
        bytes32 genesis,
        uint8 rollupCompatibilityID,
        string memory description
    ) external onlyRole(_ADD_ROLLUP_TYPE_ROLE) {
        // nullify rollup type?¿ review hash(verifier, implementation, genesis)
        // review check address are not 0?

        uint32 rollupTypeID = ++rollupTypeCount;

        rollupTypeMap[rollupTypeID] = RollupType({
            consensusImplementation: consensusImplementation,
            verifier: verifier,
            forkID: forkID,
            rollupCompatibilityID: rollupCompatibilityID,
            obsolete: false,
            genesis: genesis,
            description: description
        });

        emit AddNewRollupType(
            rollupTypeID,
            consensusImplementation,
            address(verifier),
            forkID,
            genesis,
            description
        );
    }

    /**
     * @notice Obsolete Rollup type
     * @param rollupTypeID Consensus address to obsolete
     */
    function obsoleteRollupType(
        uint32 rollupTypeID
    ) external onlyRole(_DELETE_ROLLUP_TYPE_ROLE) {
        if (rollupTypeID == 0 || rollupTypeID > rollupTypeCount) {
            revert RollupTypeDoesNotExist();
        }

        rollupTypeMap[rollupTypeID].obsolete = true;

        emit DeleteRollupType(rollupTypeID);
    }

    /**
     * @notice Create a new rollup
     * @param rollupTypeID Rollup type to deploy
     * @param chainID chainID
     * @param admin admin of the new created rollup
     * @param trustedSequencer trusted sequencer of the new created rollup
     * @param gasTokenAddress native token address
     * @param gasTokenNetwork native token network
     * @param trustedSequencerURL trusted sequencer URL of the new created rollup
     * @param networkName network name of the new created rollup
     */
    function createNewRollup(
        uint32 rollupTypeID,
        uint64 chainID,
        address admin,
        address trustedSequencer,
        address gasTokenAddress,
        uint32 gasTokenNetwork,
        string memory trustedSequencerURL,
        string memory networkName
    ) external onlyRole(_CREATE_ROLLUP_ROLE) {
        // Check that rollup type exists
        if (rollupTypeID == 0 || rollupTypeID > rollupTypeCount) {
            revert RollupTypeDoesNotExist();
        }

        // Check rollup type is not obsolete
        RollupType storage rollupType = rollupTypeMap[rollupTypeID];
        if (rollupType.obsolete == true) {
            revert RollupTypeObsolete();
        }

        // Check chainID nullifier
        if (chainIDToRollupID[chainID] != 0) {
            revert ChainIDAlreadyExist();
        }

        // Create a new Rollup, using a transparent proxy pattern
        // Consensus will be the implementation, and this contract the admin
        uint32 rollupID = ++rollupCount;
        address rollupAddress = address(
            new TransparentUpgradeableProxy(
                rollupType.consensusImplementation,
                address(this),
                abi.encodeCall(
                    IPolygonRollupBase.initialize,
                    (
                        admin,
                        trustedSequencer,
                        rollupID,
                        gasTokenAddress,
                        gasTokenNetwork,
                        trustedSequencerURL,
                        networkName
                    )
                )
            )
        );

        // Set chainID nullifier
        chainIDToRollupID[chainID] = rollupID;

        // Store rollup data
        rollupAddressToID[rollupAddress] = rollupID;

        RollupData storage rollup = rollupIDToRollupData[rollupID];

        rollup.rollupContract = IPolygonRollupBase(rollupAddress);
        rollup.forkID = rollupType.forkID;
        rollup.verifier = rollupType.verifier;
        rollup.chainID = chainID;
        rollup.batchNumToStateRoot[0] = rollupType.genesis;
        rollup.rollupTypeID = rollupTypeID;
        rollup.rollupCompatibilityID = rollupType.rollupCompatibilityID;

        emit CreateNewRollup(rollupID, rollupTypeID, rollupAddress, chainID);
    }

    /**
     * @notice Add an already deployed rollup
     * @param rollupAddress rollup address
     * @param verifier verifier address, must be added before
     * @param forkID chain id of the created rollup
     * @param chainID chain id of the created rollup
     * @param genesis chain id of the created rollup
     * @param rollupCompatibilityID chain id of the created rollup
     */
    function addExistingRollup(
        IPolygonRollupBase rollupAddress,
        IVerifierRollup verifier,
        uint64 forkID,
        uint64 chainID,
        bytes32 genesis,
        uint8 rollupCompatibilityID
    ) external onlyRole(_ADD_EXISTING_ROLLUP_ROLE) {
        // Check chainID nullifier
        if (chainIDToRollupID[chainID] != 0) {
            revert ChainIDAlreadyExist();
        }

        RollupData storage rollup = _addExistingRollup(
            rollupAddress,
            verifier,
            forkID,
            chainID,
            rollupCompatibilityID
        );
        rollup.batchNumToStateRoot[0] = genesis;
    }

    /**
     * @notice Add an already deployed rollup
     * @param rollupAddress rollup address
     * @param verifier verifier address, must be added before
     * @param forkID chain id of the created rollup
     * @param chainID chain id of the created rollup
     * @param rollupCompatibilityID chain id of the created rollup
     */
    function _addExistingRollup(
        IPolygonRollupBase rollupAddress,
        IVerifierRollup verifier,
        uint64 forkID,
        uint64 chainID,
        uint8 rollupCompatibilityID
    ) internal returns (RollupData storage rollup) {
        uint32 rollupID = ++rollupCount;

        // Set chainID nullifier
        chainIDToRollupID[chainID] = rollupID;

        // Store rollup data
        rollupAddressToID[address(rollupAddress)] = rollupID;

        rollup = rollupIDToRollupData[rollupID];
        rollup.rollupContract = rollupAddress;
        rollup.forkID = forkID;
        rollup.verifier = verifier;
        rollup.chainID = chainID;
        rollup.rollupCompatibilityID = rollupCompatibilityID;

        emit AddExistingRollup(
            rollupID,
            forkID,
            address(rollupAddress),
            chainID,
            rollupCompatibilityID
        );
    }

    //review, should cehck that there are not sequenced batches eponding to be verified?¿?
    //this way no one can break the virtual state, ( but maybe is worth to break it)

    /**
     * @notice Upgrade an existing rollup
     * @param rollupContract Rollup consensus proxy address
     * @param newRollupTypeID New rolluptypeID to upgrade to
     * @param upgradeData Upgrade data
     */
    function updateRollup(
        TransparentUpgradeableProxy rollupContract,
        uint32 newRollupTypeID,
        bytes calldata upgradeData
    ) external onlyRole(_UPDATE_ROLLUP_ROLE) {
        // TODO Check new rollup type was not deleted? it would be sanity check
        // Check that rollup type exists
        if (newRollupTypeID == 0 || newRollupTypeID > rollupTypeCount) {
            revert RollupTypeDoesNotExist();
        }

        uint32 rollupID = rollupAddressToID[address(rollupContract)];
        if (rollupID == 0) {
            revert RollupMustExist();
        }

        RollupData storage rollup = rollupIDToRollupData[rollupID];

        if (rollup.rollupTypeID == newRollupTypeID) {
            revert UpdateToSameRollupTypeID();
        }

        RollupType storage newRollupType = rollupTypeMap[newRollupTypeID];

        // Check rollup type is not obsolete
        if (newRollupType.obsolete == true) {
            revert RollupTypeObsolete();
        }

        // check compatibility of the rollups
        if (
            rollup.rollupCompatibilityID != newRollupType.rollupCompatibilityID
        ) {
            revert UpdateToSameRollupTypeID();
        }

        // update rollup parameters
        rollup.verifier = newRollupType.verifier;
        rollup.forkID = newRollupType.forkID;
        rollup.rollupTypeID = newRollupTypeID;
        rollup.lastVerifiedBatchBeforeUpgrade = getLastVerifiedBatch(rollupID);

        // review if it's the same implementation do not upgrade
        address newConsensusAddress = newRollupType.consensusImplementation;
        if (rollupContract.implementation() != newConsensusAddress) {
            rollupContract.upgradeToAndCall(newConsensusAddress, upgradeData);
        }

        emit UpdateRollup(
            rollupID,
            newRollupTypeID,
            rollup.lastVerifiedBatchBeforeUpgrade
        );
    }

    /////////////////////////////////////
    // Sequence/Verify batches functions
    ////////////////////////////////////

    /**
     * @notice Sequence batches, callback called by one of the consensus managed by this contract
     * @param newSequencedBatches how many sequenced batches were sequenced
     * @param forcedSequencedBatches how many forced batches were sequenced
     * @param newAccInputHash new accumualted input hash
     */
    function onSequenceBatches(
        uint64 newSequencedBatches,
        uint64 forcedSequencedBatches,
        bytes32 newAccInputHash
    ) external ifNotEmergencyState returns (uint64) {
        // Check that the msg.sender is an added rollup
        uint32 rollupID = rollupAddressToID[msg.sender];
        if (rollupID == 0) {
            revert SenderMustBeRollup();
        }

        RollupData storage rollup = rollupIDToRollupData[rollupID];

        // Update total sequence parameters
        if (newSequencedBatches == 0) {
            revert MustSequenceSomeBatch();
        }

        totalSequencedBatches += newSequencedBatches;

        if (forcedSequencedBatches != 0) {
            totalPendingForcedBatches -= forcedSequencedBatches;
        }

        // Update sequenced batches of the current rollup
        uint64 previousLastBatchSequenced = rollup.lastBatchSequenced;
        uint64 newLastBatchSequenced = previousLastBatchSequenced +
            newSequencedBatches;

        rollup.lastBatchSequenced = newLastBatchSequenced;
        rollup.sequencedBatches[newLastBatchSequenced] = SequencedBatchData({
            accInputHash: newAccInputHash,
            sequencedTimestamp: uint64(block.timestamp),
            previousLastBatchSequenced: previousLastBatchSequenced
        });

        // Consolidate pending state if possible
        _tryConsolidatePendingState(rollup);

        emit OnSequenceBatches(rollupID, newLastBatchSequenced);

        // COMMENT: Is this return needed ?
        return newLastBatchSequenced;
    }

    /**
     * @notice Allows an aggregator to verify multiple batches
     * @param pendingStateNum Init pending state, 0 if consolidated state is used
     * @param initNumBatch Batch which the aggregator starts the verification
     * @param finalNewBatch Last batch aggregator intends to verify
     * @param newLocalExitRoot  New local exit root once the batch is processed
     * @param newStateRoot New State root once the batch is processed
     * @param proof fflonk proof
     */
    function verifyBatches(
        uint32 rollupID,
        uint64 pendingStateNum,
        uint64 initNumBatch,
        uint64 finalNewBatch,
        bytes32 newLocalExitRoot,
        bytes32 newStateRoot,
        address beneficiary,
        bytes32[24] calldata proof
    ) external ifNotEmergencyState {
        RollupData storage rollup = rollupIDToRollupData[rollupID];

        // Check if the trusted aggregator timeout expired,
        // Note that the sequencedBatches struct must exists for this finalNewBatch, if not newAccInputHash will be 0
        if (
            rollup.sequencedBatches[finalNewBatch].sequencedTimestamp +
                trustedAggregatorTimeout >
            block.timestamp
        ) {
            revert TrustedAggregatorTimeoutNotExpired();
        }

        if (finalNewBatch - initNumBatch > _MAX_VERIFY_BATCHES) {
            revert ExceedMaxVerifyBatches();
        }

        _verifyAndRewardBatches(
            rollup,
            pendingStateNum,
            initNumBatch,
            finalNewBatch,
            newLocalExitRoot,
            newStateRoot,
            beneficiary,
            proof
        );

        // Update batch fees
        // review, shoudl update awell in the ntrusted aggregation?
        _updateBatchFee(rollup, finalNewBatch);

        if (pendingStateTimeout == 0) {
            // Consolidate state
            rollup.lastVerifiedBatch = finalNewBatch;
            rollup.batchNumToStateRoot[finalNewBatch] = newStateRoot;
            rollup.lastLocalExitRoot = newLocalExitRoot;

            // Clean pending state if any
            if (rollup.lastPendingState > 0) {
                rollup.lastPendingState = 0;
                rollup.lastPendingStateConsolidated = 0;
            }

            // Interact with globalExitRootManager
            globalExitRootManager.updateExitRoot(getRollupExitRoot());
        } else {
            // Consolidate pending state if possible
            _tryConsolidatePendingState(rollup);

            // Update pending state
            rollup.lastPendingState++;
            rollup.pendingStateTransitions[
                rollup.lastPendingState
            ] = PendingState({
                timestamp: uint64(block.timestamp),
                lastVerifiedBatch: finalNewBatch,
                exitRoot: newLocalExitRoot,
                stateRoot: newStateRoot
            });
        }

        emit VerifyBatches(rollupID, finalNewBatch, newStateRoot, msg.sender);
    }

    /**
     * @notice Allows an aggregator to verify multiple batches
     * @param pendingStateNum Init pending state, 0 if consolidated state is used
     * @param initNumBatch Batch which the aggregator starts the verification
     * @param finalNewBatch Last batch aggregator intends to verify
     * @param newLocalExitRoot  New local exit root once the batch is processed
     * @param newStateRoot New State root once the batch is processed
     * @param proof fflonk proof
     */
    function verifyBatchesTrustedAggregator(
        uint32 rollupID,
        uint64 pendingStateNum,
        uint64 initNumBatch,
        uint64 finalNewBatch,
        bytes32 newLocalExitRoot,
        bytes32 newStateRoot,
        address beneficiary,
        bytes32[24] calldata proof
    ) external onlyRole(_TRUSTED_AGGREGATOR_ROLE) {
        RollupData storage rollup = rollupIDToRollupData[rollupID];

        _verifyAndRewardBatches(
            rollup,
            pendingStateNum,
            initNumBatch,
            finalNewBatch,
            newLocalExitRoot,
            newStateRoot,
            beneficiary,
            proof
        );

        // Consolidate state
        rollup.lastVerifiedBatch = finalNewBatch;
        rollup.batchNumToStateRoot[finalNewBatch] = newStateRoot;
        rollup.lastLocalExitRoot = newLocalExitRoot;

        // Clean pending state if any
        if (rollup.lastPendingState > 0) {
            rollup.lastPendingState = 0;
            rollup.lastPendingStateConsolidated = 0;
        }

        // Interact with globalExitRootManager
        globalExitRootManager.updateExitRoot(getRollupExitRoot());

        emit VerifyBatchesTrustedAggregator(
            rollupID,
            finalNewBatch,
            newStateRoot,
            msg.sender
        );
    }

    /**
     * @notice Verify and reward batches internal function
     * @param pendingStateNum Init pending state, 0 if consolidated state is used
     * @param initNumBatch Batch which the aggregator starts the verification
     * @param finalNewBatch Last batch aggregator intends to verify
     * @param newLocalExitRoot  New local exit root once the batch is processed
     * @param newStateRoot New State root once the batch is processed
     * @param proof fflonk proof
     */
    function _verifyAndRewardBatches(
        RollupData storage rollup,
        uint64 pendingStateNum,
        uint64 initNumBatch,
        uint64 finalNewBatch,
        bytes32 newLocalExitRoot,
        bytes32 newStateRoot,
        address beneficiary,
        bytes32[24] calldata proof
    ) internal virtual {
        bytes32 oldStateRoot;
        uint64 currentLastVerifiedBatch = _getLastVerifiedBatch(rollup);

        if (initNumBatch < rollup.lastVerifiedBatchBeforeUpgrade) {
            revert InitBatchMustMatchCurrentForkID();
        }

        // Use pending state if specified, otherwise use consolidated state
        if (pendingStateNum != 0) {
            // Check that pending state exist
            // Already consolidated pending states can be used aswell
            if (pendingStateNum > rollup.lastPendingState) {
                revert PendingStateDoesNotExist();
            }

            // Check choosen pending state
            PendingState storage currentPendingState = rollup
                .pendingStateTransitions[pendingStateNum];

            // Get oldStateRoot from pending batch
            oldStateRoot = currentPendingState.stateRoot;

            // Check initNumBatch matches the pending state
            if (initNumBatch != currentPendingState.lastVerifiedBatch) {
                revert InitNumBatchDoesNotMatchPendingState();
            }
        } else {
            // Use consolidated state
            oldStateRoot = rollup.batchNumToStateRoot[initNumBatch];

            if (oldStateRoot == bytes32(0)) {
                revert OldStateRootDoesNotExist();
            }

            // Check initNumBatch is inside the range, sanity check
            if (initNumBatch > currentLastVerifiedBatch) {
                revert InitNumBatchAboveLastVerifiedBatch();
            }
        }

        // Check final batch
        if (finalNewBatch <= currentLastVerifiedBatch) {
            revert FinalNumBatchBelowLastVerifiedBatch();
        }

        // Get snark bytes
        bytes memory snarkHashBytes = _getInputSnarkBytes(
            rollup,
            initNumBatch,
            finalNewBatch,
            newLocalExitRoot,
            oldStateRoot,
            newStateRoot
        );

        // Calulate the snark input
        uint256 inputSnark = uint256(sha256(snarkHashBytes)) % _RFIELD;

        // Verify proof
        if (!rollup.verifier.verifyProof(proof, [inputSnark])) {
            revert InvalidProof();
        }

        // Pay MATIC rewards
        uint64 newVerifiedBatches = finalNewBatch - currentLastVerifiedBatch;

        matic.safeTransfer(
            beneficiary,
            calculateRewardPerBatch() * newVerifiedBatches
        );

        // Update aggregation parameters
        totalVerifiedBatches += newVerifiedBatches;
        lastAggregationTimestamp = uint64(block.timestamp);

        // Callback to the rollup address
        rollup.rollupContract.onVerifyBatches(
            finalNewBatch,
            newStateRoot,
            msg.sender
        );
    }

    /**
     * @notice Internal function to consolidate the state automatically once sequence or verify batches are called
     * It tries to consolidate the first and the middle pending state in the queue
     */
    function _tryConsolidatePendingState(RollupData storage rollup) internal {
        // Check if there's any state to consolidate
        if (rollup.lastPendingState > rollup.lastPendingStateConsolidated) {
            // Check if it's possible to consolidate the next pending state
            uint64 nextPendingState = rollup.lastPendingStateConsolidated + 1;
            if (_isPendingStateConsolidable(rollup, nextPendingState)) {
                // Check middle pending state ( binary search of 1 step)
                uint64 middlePendingState = nextPendingState +
                    (rollup.lastPendingState - nextPendingState) /
                    2;

                // Try to consolidate it, and if not, consolidate the nextPendingState
                if (_isPendingStateConsolidable(rollup, middlePendingState)) {
                    _consolidatePendingState(rollup, middlePendingState);
                } else {
                    _consolidatePendingState(rollup, nextPendingState);
                }
            }
        }
    }

    /**
     * @notice Allows to consolidate any pending state that has already exceed the pendingStateTimeout
     * Can be called by the trusted aggregator, which can consolidate any state without the timeout restrictions
     * @param pendingStateNum Pending state to consolidate
     */
    function consolidatePendingState(
        uint32 rollupID,
        uint64 pendingStateNum
    ) external {
        RollupData storage rollup = rollupIDToRollupData[rollupID];
        // Check if pending state can be consolidated
        // If trusted aggregator is the sender, do not check the timeout or the emergency state
        if (!hasRole(_TRUSTED_AGGREGATOR_ROLE, msg.sender)) {
            if (isEmergencyState) {
                revert OnlyNotEmergencyState();
            }

            if (!_isPendingStateConsolidable(rollup, pendingStateNum)) {
                revert PendingStateNotConsolidable();
            }
        }
        _consolidatePendingState(rollup, pendingStateNum);
    }

    /**
     * @notice Internal function to consolidate any pending state that has already exceed the pendingStateTimeout
     * @param pendingStateNum Pending state to consolidate
     */
    function _consolidatePendingState(
        RollupData storage rollup,
        uint64 pendingStateNum
    ) internal {
        // Check if pendingStateNum is in correct range
        // - not consolidated (implicity checks that is not 0)
        // - exist ( has been added)
        if (
            pendingStateNum <= rollup.lastPendingStateConsolidated ||
            pendingStateNum > rollup.lastPendingState
        ) {
            revert PendingStateInvalid();
        }

        PendingState storage currentPendingState = rollup
            .pendingStateTransitions[pendingStateNum];

        // Update state
        uint64 newLastVerifiedBatch = currentPendingState.lastVerifiedBatch;
        rollup.lastVerifiedBatch = newLastVerifiedBatch;
        rollup.batchNumToStateRoot[newLastVerifiedBatch] = currentPendingState
            .stateRoot;

        // Update pending state
        rollup.lastPendingStateConsolidated = pendingStateNum;

        // Interact with globalExitRootManager
        globalExitRootManager.updateExitRoot(currentPendingState.exitRoot);

        emit ConsolidatePendingState(
            rollupAddressToID[address(rollup.rollupContract)],
            newLastVerifiedBatch,
            currentPendingState.stateRoot,
            pendingStateNum
        );
    }

    /////////////////////////////////
    // Soundness protection functions
    /////////////////////////////////

    /**
     * @notice Allows the trusted aggregator to override the pending state
     * if it's possible to prove a different state root given the same batches
     * @param initPendingStateNum Init pending state, 0 if consolidated state is used
     * @param finalPendingStateNum Final pending state, that will be used to compare with the newStateRoot
     * @param initNumBatch Batch which the aggregator starts the verification
     * @param finalNewBatch Last batch aggregator intends to verify
     * @param newLocalExitRoot  New local exit root once the batch is processed
     * @param newStateRoot New State root once the batch is processed
     * @param proof fflonk proof
     */
    function overridePendingState(
        uint32 rollupID,
        uint64 initPendingStateNum,
        uint64 finalPendingStateNum,
        uint64 initNumBatch,
        uint64 finalNewBatch,
        bytes32 newLocalExitRoot,
        bytes32 newStateRoot,
        bytes32[24] calldata proof
    ) external onlyRole(_TRUSTED_AGGREGATOR_ROLE) {
        RollupData storage rollup = rollupIDToRollupData[rollupID];

        _proveDistinctPendingState(
            rollup,
            initPendingStateNum,
            finalPendingStateNum,
            initNumBatch,
            finalNewBatch,
            newLocalExitRoot,
            newStateRoot,
            proof
        );

        // Consolidate state state
        rollup.lastVerifiedBatch = finalNewBatch;
        rollup.batchNumToStateRoot[finalNewBatch] = newStateRoot;
        rollup.lastLocalExitRoot = newLocalExitRoot;

        // Clean pending state if any
        if (rollup.lastPendingState > 0) {
            rollup.lastPendingState = 0;
            rollup.lastPendingStateConsolidated = 0;
        }

        // Interact with globalExitRootManager
        globalExitRootManager.updateExitRoot(getRollupExitRoot());

        // Update trusted aggregator timeout to max
        trustedAggregatorTimeout = _HALT_AGGREGATION_TIMEOUT;

        emit OverridePendingState(finalNewBatch, newStateRoot, msg.sender);
    }

    /**
     * @notice Allows to halt the PolygonZkEVM if its possible to prove a different state root given the same batches
     * @param initPendingStateNum Init pending state, 0 if consolidated state is used
     * @param finalPendingStateNum Final pending state, that will be used to compare with the newStateRoot
     * @param initNumBatch Batch which the aggregator starts the verification
     * @param finalNewBatch Last batch aggregator intends to verify
     * @param newLocalExitRoot  New local exit root once the batch is processed
     * @param newStateRoot New State root once the batch is processed
     * @param proof fflonk proof
     */
    function proveNonDeterministicPendingState(
        uint32 rollupID,
        uint64 initPendingStateNum,
        uint64 finalPendingStateNum,
        uint64 initNumBatch,
        uint64 finalNewBatch,
        bytes32 newLocalExitRoot,
        bytes32 newStateRoot,
        bytes32[24] calldata proof
    ) external ifNotEmergencyState {
        RollupData storage rollup = rollupIDToRollupData[rollupID];

        _proveDistinctPendingState(
            rollup,
            initPendingStateNum,
            finalPendingStateNum,
            initNumBatch,
            finalNewBatch,
            newLocalExitRoot,
            newStateRoot,
            proof
        );

        emit ProveNonDeterministicPendingState(
            rollup.batchNumToStateRoot[finalNewBatch],
            newStateRoot
        );

        // Activate emergency state
        _activateEmergencyState();
    }

    /**
     * @notice Internal function that proves a different state root given the same batches to verify
     * @param initPendingStateNum Init pending state, 0 if consolidated state is used
     * @param finalPendingStateNum Final pending state, that will be used to compare with the newStateRoot
     * @param initNumBatch Batch which the aggregator starts the verification
     * @param finalNewBatch Last batch aggregator intends to verify
     * @param newLocalExitRoot  New local exit root once the batch is processed
     * @param newStateRoot New State root once the batch is processed
     * @param proof fflonk proof
     */
    function _proveDistinctPendingState(
        RollupData storage rollup,
        uint64 initPendingStateNum,
        uint64 finalPendingStateNum,
        uint64 initNumBatch,
        uint64 finalNewBatch,
        bytes32 newLocalExitRoot,
        bytes32 newStateRoot,
        bytes32[24] calldata proof
    ) internal view virtual {
        bytes32 oldStateRoot;

        if (initNumBatch < rollup.lastVerifiedBatchBeforeUpgrade) {
            revert InitBatchMustMatchCurrentForkID();
        }

        // Use pending state if specified, otherwise use consolidated state
        if (initPendingStateNum != 0) {
            // Check that pending state exist
            // Already consolidated pending states can be used aswell
            if (initPendingStateNum > rollup.lastPendingState) {
                revert PendingStateDoesNotExist();
            }

            // Check choosen pending state
            PendingState storage initPendingState = rollup
                .pendingStateTransitions[initPendingStateNum];

            // Get oldStateRoot from init pending state
            oldStateRoot = initPendingState.stateRoot;

            // Check initNumBatch matches the init pending state
            if (initNumBatch != initPendingState.lastVerifiedBatch) {
                revert InitNumBatchDoesNotMatchPendingState();
            }
        } else {
            // Use consolidated state
            oldStateRoot = rollup.batchNumToStateRoot[initNumBatch];
            if (oldStateRoot == bytes32(0)) {
                revert OldStateRootDoesNotExist();
            }

            // Check initNumBatch is inside the range, sanity check
            if (initNumBatch > rollup.lastVerifiedBatch) {
                revert InitNumBatchAboveLastVerifiedBatch();
            }
        }

        // Assert final pending state num is in correct range
        // - exist ( has been added)
        // - bigger than the initPendingstate
        // - not consolidated
        if (
            finalPendingStateNum > rollup.lastPendingState ||
            finalPendingStateNum <= initPendingStateNum ||
            finalPendingStateNum <= rollup.lastPendingStateConsolidated
        ) {
            revert FinalPendingStateNumInvalid();
        }

        // Check final num batch
        if (
            finalNewBatch !=
            rollup
                .pendingStateTransitions[finalPendingStateNum]
                .lastVerifiedBatch
        ) {
            revert FinalNumBatchDoesNotMatchPendingState();
        }

        // Get snark bytes
        bytes memory snarkHashBytes = _getInputSnarkBytes(
            rollup,
            initNumBatch,
            finalNewBatch,
            newLocalExitRoot,
            oldStateRoot,
            newStateRoot
        );

        // Calulate the snark input
        uint256 inputSnark = uint256(sha256(snarkHashBytes)) % _RFIELD;

        // Verify proof
        if (!rollup.verifier.verifyProof(proof, [inputSnark])) {
            revert InvalidProof();
        }

        if (
            rollup.pendingStateTransitions[finalPendingStateNum].stateRoot ==
            newStateRoot
        ) {
            revert StoredRootMustBeDifferentThanNewRoot();
        }
    }

    /**
     * @notice Function to update the batch fee based on the new verified batches
     * The batch fee will not be updated when the trusted aggregator verifies batches
     * @param newLastVerifiedBatch New last verified batch
     */
    function _updateBatchFee(
        RollupData storage rollup,
        uint64 newLastVerifiedBatch
    ) internal {
        uint64 currentLastVerifiedBatch = _getLastVerifiedBatch(rollup);
        uint64 currentBatch = newLastVerifiedBatch;

        uint256 totalBatchesAboveTarget;
        uint256 newBatchesVerified = newLastVerifiedBatch -
            currentLastVerifiedBatch;

        uint256 targetTimestamp = block.timestamp - verifyBatchTimeTarget;

        while (currentBatch != currentLastVerifiedBatch) {
            // Load sequenced batchdata
            SequencedBatchData storage currentSequencedBatchData = rollup
                .sequencedBatches[currentBatch];

            // Check if timestamp is below the verifyBatchTimeTarget
            if (
                targetTimestamp < currentSequencedBatchData.sequencedTimestamp
            ) {
                // update currentBatch
                currentBatch = currentSequencedBatchData
                    .previousLastBatchSequenced;
            } else {
                // The rest of batches will be above
                totalBatchesAboveTarget =
                    currentBatch -
                    currentLastVerifiedBatch;
                break;
            }
        }

        uint256 totalBatchesBelowTarget = newBatchesVerified -
            totalBatchesAboveTarget;

        // _MAX_BATCH_FEE --> (< 70 bits)
        // multiplierBatchFee --> (< 10 bits)
        // _MAX_BATCH_MULTIPLIER = 12
        // multiplierBatchFee ** _MAX_BATCH_MULTIPLIER --> (< 128 bits)
        // batchFee * (multiplierBatchFee ** _MAX_BATCH_MULTIPLIER)-->
        // (< 70 bits) * (< 128 bits) = < 256 bits

        // Since all the following operations cannot overflow, we can optimize this operations with unchecked
        unchecked {
            if (totalBatchesBelowTarget < totalBatchesAboveTarget) {
                // There are more batches above target, fee is multiplied
                uint256 diffBatches = totalBatchesAboveTarget -
                    totalBatchesBelowTarget;

                diffBatches = diffBatches > _MAX_BATCH_MULTIPLIER
                    ? _MAX_BATCH_MULTIPLIER
                    : diffBatches;

                // For every multiplierBatchFee multiplication we must shift 3 zeroes since we have 3 decimals
                batchFee =
                    (batchFee * (uint256(multiplierBatchFee) ** diffBatches)) /
                    (uint256(1000) ** diffBatches);
            } else {
                // There are more batches below target, fee is divided
                uint256 diffBatches = totalBatchesBelowTarget -
                    totalBatchesAboveTarget;

                diffBatches = diffBatches > _MAX_BATCH_MULTIPLIER
                    ? _MAX_BATCH_MULTIPLIER
                    : diffBatches;

                // For every multiplierBatchFee multiplication we must shift 3 zeroes since we have 3 decimals
                uint256 accDivisor = (uint256(1 ether) *
                    (uint256(multiplierBatchFee) ** diffBatches)) /
                    (uint256(1000) ** diffBatches);

                // multiplyFactor = multiplierBatchFee ** diffBatches / 10 ** (diffBatches * 3)
                // accDivisor = 1E18 * multiplyFactor
                // 1E18 * batchFee / accDivisor = batchFee / multiplyFactor
                // < 60 bits * < 70 bits / ~60 bits --> overflow not possible
                batchFee = (uint256(1 ether) * batchFee) / accDivisor;
            }
        }

        // Batch fee must remain inside a range
        if (batchFee > _MAX_BATCH_FEE) {
            batchFee = _MAX_BATCH_FEE;
        } else if (batchFee < _MIN_BATCH_FEE) {
            batchFee = _MIN_BATCH_FEE;
        }
    }

    ////////////////////////
    // Emergency state functions
    ////////////////////////

    /**
     * @notice Function to activate emergency state, which also enables the emergency mode on both PolygonZkEVM and PolygonZkEVMBridge contracts
     * If not called by the owner must not have been aggregated in a _HALT_AGGREGATION_TIMEOUT period
     */
    function activateEmergencyState() external {
        if (!hasRole(_EMERGENCY_COUNCIL_ROLE, msg.sender)) {
            if (
                lastAggregationTimestamp + _HALT_AGGREGATION_TIMEOUT >
                block.timestamp
            ) {
                revert HaltTimeoutNotExpired();
            }
        }
        _activateEmergencyState();
    }

    /**
     * @notice Function to deactivate emergency state on both PolygonZkEVM and PolygonZkEVMBridge contracts
     */
    function deactivateEmergencyState()
        external
        onlyRole(_STOP_EMERGENCY_ROLE)
    {
        // Deactivate emergency state on PolygonZkEVMBridge
        bridgeAddress.deactivateEmergencyState();

        // Deactivate emergency state on this contract
        super._deactivateEmergencyState();
    }

    /**
     * @notice Internal function to activate emergency state on both PolygonZkEVM and PolygonZkEVMBridge contracts
     */
    function _activateEmergencyState() internal override {
        // Activate emergency state on PolygonZkEVM Bridge
        bridgeAddress.activateEmergencyState();

        // Activate emergency state on this contract
        super._activateEmergencyState();
    }

    //////////////////
    // admin functions
    //////////////////

    /**
     * @notice Allow the admin to set a new trusted aggregator address
     * @param newTrustedAggregator Address of the new trusted aggregator
     */
    function setTrustedAggregator(
        address newTrustedAggregator
    ) external onlyRole(_TRUSTED_AGGREGATOR_ROLE) {
        trustedAggregator = newTrustedAggregator;

        emit SetTrustedAggregator(newTrustedAggregator);
    }

    /**
     * @notice Allow the admin to set a new pending state timeout
     * The timeout can only be lowered, except if emergency state is active
     * @param newTrustedAggregatorTimeout Trusted aggregator timeout
     */
    function setTrustedAggregatorTimeout(
        uint64 newTrustedAggregatorTimeout
    ) external onlyRole(_TWEAK_PARAMETERS_ROLE) {
        if (!isEmergencyState) {
            if (newTrustedAggregatorTimeout >= trustedAggregatorTimeout) {
                revert NewTrustedAggregatorTimeoutMustBeLower();
            }
        }

        trustedAggregatorTimeout = newTrustedAggregatorTimeout;
        emit SetTrustedAggregatorTimeout(newTrustedAggregatorTimeout);
    }

    /**
     * @notice Allow the admin to set a new trusted aggregator timeout
     * The timeout can only be lowered, except if emergency state is active
     * @param newPendingStateTimeout Trusted aggregator timeout
     */
    function setPendingStateTimeout(
        uint64 newPendingStateTimeout
    ) external onlyRole(_TWEAK_PARAMETERS_ROLE) {
        if (!isEmergencyState) {
            if (newPendingStateTimeout >= pendingStateTimeout) {
                revert NewPendingStateTimeoutMustBeLower();
            }
        }

        pendingStateTimeout = newPendingStateTimeout;
        emit SetPendingStateTimeout(newPendingStateTimeout);
    }

    /**
     * @notice Allow the admin to set a new multiplier batch fee
     * @param newMultiplierBatchFee multiplier batch fee
     */
    function setMultiplierBatchFee(
        uint16 newMultiplierBatchFee
    ) external onlyRole(_TWEAK_PARAMETERS_ROLE) {
        if (newMultiplierBatchFee < 1000 || newMultiplierBatchFee > 1023) {
            revert InvalidRangeMultiplierBatchFee();
        }

        multiplierBatchFee = newMultiplierBatchFee;
        emit SetMultiplierBatchFee(newMultiplierBatchFee);
    }

    /**
     * @notice Allow the admin to set a new verify batch time target
     * This value will only be relevant once the aggregation is decentralized, so
     * the trustedAggregatorTimeout should be zero or very close to zero
     * @param newVerifyBatchTimeTarget Verify batch time target
     */
    function setVerifyBatchTimeTarget(
        uint64 newVerifyBatchTimeTarget
    ) external onlyRole(_TWEAK_PARAMETERS_ROLE) {
        if (newVerifyBatchTimeTarget > 1 days) {
            revert InvalidRangeBatchTimeTarget();
        }
        verifyBatchTimeTarget = newVerifyBatchTimeTarget;
        emit SetVerifyBatchTimeTarget(newVerifyBatchTimeTarget);
    }

    /**
     * @notice Allow to corresponding role to set the current batch fee
     * @param newBatchFee new batch fee
     */
    function setBatchFee(uint256 newBatchFee) external onlyRole(_SET_FEE_ROLE) {
        batchFee = newBatchFee;
        emit SetBatchFee(newBatchFee);
    }

    ////////////////////////
    // view/pure functions
    ///////////////////////

    /**
     * @notice Get the current rollup exit root
     * Compute using all the local exit roots of all rollups the rollup exit root
     * Since it's expected to have no more than 10 rollups in this first version, even if this approach
     * has a gas consumption that scales linearly with the rollups added, it's ok
     * In a future versions this computation will be done inside the circuit
     */
    function getRollupExitRoot() public view returns (bytes32) {
        uint256 currentNodes = rollupCount;

        // if there are no nodes return 0
        if (currentNodes == 0) {
            return bytes32(0);
        }

        // This array will contain the nodes of the current iteration
        bytes32[] memory tmpTree = new bytes32[](currentNodes);

        // In the first iteration the nodes will be the leafs which are the local exit roots of each network
        for (uint256 i = 0; i < currentNodes; i++) {
            tmpTree[i] = rollupIDToRollupData[uint32(i)].lastLocalExitRoot;
        }

        // This variable will keep track of the zero hashes
        bytes32 currentZeroHashHeight = 0;

        // This variable will keep track of the reamining levels to compute
        uint256 remainingLevels = _EXIT_TREE_DEPTH;

        // Calculate the root of the sub-tree that contains all the localExitRoots
        while (currentNodes != 1) {
            uint256 nextIterationNodes = currentNodes / 2 + (currentNodes % 2);
            bytes32[] memory nextTmpTree = new bytes32[](nextIterationNodes);
            for (uint256 i = 0; i < nextIterationNodes; i++) {
                // if we are on the last iteration of the current level and the nodes are odd
                if (i == nextIterationNodes - 1 && (currentNodes % 2) == 1) {
                    nextTmpTree[i] = keccak256(
                        abi.encodePacked(tmpTree[i * 2], currentZeroHashHeight)
                    );
                } else {
                    nextTmpTree[i] = keccak256(
                        abi.encodePacked(tmpTree[i * 2], tmpTree[(i * 2) + 1])
                    );
                }
            }

            // update tree bariables
            tmpTree = nextTmpTree;
            currentNodes = nextIterationNodes;
            currentZeroHashHeight = keccak256(
                abi.encodePacked(currentZeroHashHeight, currentZeroHashHeight)
            );
            remainingLevels--;
        }

        bytes32 currentRoot = tmpTree[0];

        // Calculate remaining levels, since it's a sequencial merkle tree, the rest of the tree are zeroes
        for (uint256 i = 0; i < remainingLevels; i++) {
            currentRoot = keccak256(
                abi.encodePacked(currentRoot, currentZeroHashHeight)
            );
            currentZeroHashHeight = keccak256(
                abi.encodePacked(currentZeroHashHeight, currentZeroHashHeight)
            );
        }
        return currentRoot;
    }

    /**
     * @notice Get the last verified batch
     */
    function getLastVerifiedBatch(
        uint32 rollupID
    ) public view returns (uint64) {
        return _getLastVerifiedBatch(rollupIDToRollupData[rollupID]);
    }

    /**
     * @notice Get the last verified batch
     */
    function _getLastVerifiedBatch(
        RollupData storage rollup
    ) internal view returns (uint64) {
        if (rollup.lastPendingState > 0) {
            return
                rollup
                    .pendingStateTransitions[rollup.lastPendingState]
                    .lastVerifiedBatch;
        } else {
            return rollup.lastVerifiedBatch;
        }
    }

    /**
     * @notice Returns a boolean that indicates if the pendingStateNum is or not consolidable
     * Note that his function does not check if the pending state currently exists, or if it's consolidated already
     */
    function isPendingStateConsolidable(
        uint32 rollupID,
        uint64 pendingStateNum
    ) public view returns (bool) {
        return
            _isPendingStateConsolidable(
                rollupIDToRollupData[rollupID],
                pendingStateNum
            );
    }

    /**
     * @notice Returns a boolean that indicates if the pendingStateNum is or not consolidable
     * Note that his function does not check if the pending state currently exists, or if it's consolidated already
     */
    function _isPendingStateConsolidable(
        RollupData storage rollup,
        uint64 pendingStateNum
    ) internal view returns (bool) {
        return (rollup.pendingStateTransitions[pendingStateNum].timestamp +
            pendingStateTimeout <=
            block.timestamp);
    }

    /**
     * @notice Function to calculate the reward to verify a single batch
     */
    function calculateRewardPerBatch() public view returns (uint256) {
        uint256 currentBalance = matic.balanceOf(address(this));

        // Total Sequenced Batches = total forcedBatches to be sequenced + total Sequenced Batches
        // Total Batches to be verified = total Sequenced Batches - total verified Batches
        uint256 totalBatchesToVerify = (totalPendingForcedBatches +
            totalSequencedBatches) - totalVerifiedBatches;

        if (totalBatchesToVerify == 0) return 0;
        return currentBalance / totalBatchesToVerify;
    }

    /**
     * @notice Get batch fee
     */
    function getBatchFee() public view returns (uint256) {
        return batchFee;
    }

    /**
     * @notice Get forced batch fee
     */
    function getForcedBatchFee() public view returns (uint256) {
        return batchFee * 100;
    }

    /**
     * @notice Function to calculate the input snark bytes
     * @param initNumBatch Batch which the aggregator starts the verification
     * @param finalNewBatch Last batch aggregator intends to verify
     * @param newLocalExitRoot New local exit root once the batch is processed
     * @param oldStateRoot State root before batch is processed
     * @param newStateRoot New State root once the batch is processed
     */
    function getInputSnarkBytes(
        uint32 rollupID,
        uint64 initNumBatch,
        uint64 finalNewBatch,
        bytes32 newLocalExitRoot,
        bytes32 oldStateRoot,
        bytes32 newStateRoot
    ) public view returns (bytes memory) {
        return
            _getInputSnarkBytes(
                rollupIDToRollupData[rollupID],
                initNumBatch,
                finalNewBatch,
                newLocalExitRoot,
                oldStateRoot,
                newStateRoot
            );
    }

    /**
     * @notice Function to calculate the input snark bytes
     * @param initNumBatch Batch which the aggregator starts the verification
     * @param finalNewBatch Last batch aggregator intends to verify
     * @param newLocalExitRoot New local exit root once the batch is processed
     * @param oldStateRoot State root before batch is processed
     * @param newStateRoot New State root once the batch is processed
     */
    function _getInputSnarkBytes(
        RollupData storage rollup,
        uint64 initNumBatch,
        uint64 finalNewBatch,
        bytes32 newLocalExitRoot,
        bytes32 oldStateRoot,
        bytes32 newStateRoot
    ) internal view returns (bytes memory) {
        // sanity checks
        bytes32 oldAccInputHash = rollup
            .sequencedBatches[initNumBatch]
            .accInputHash;

        bytes32 newAccInputHash = rollup
            .sequencedBatches[finalNewBatch]
            .accInputHash;

        // sanity checks
        if (initNumBatch != 0 && oldAccInputHash == bytes32(0)) {
            revert OldAccInputHashDoesNotExist();
        }

        if (newAccInputHash == bytes32(0)) {
            revert NewAccInputHashDoesNotExist();
        }

        // Check that new state root is inside goldilocks field
        if (!_checkStateRootInsidePrime(uint256(newStateRoot))) {
            revert NewStateRootNotInsidePrime();
        }

        return
            abi.encodePacked(
                msg.sender,
                oldStateRoot,
                oldAccInputHash,
                initNumBatch,
                rollup.chainID,
                rollup.forkID,
                newStateRoot,
                newAccInputHash,
                newLocalExitRoot,
                finalNewBatch
            );
    }

    function _checkStateRootInsidePrime(
        uint256 newStateRoot
    ) internal pure returns (bool) {
        if (
            ((newStateRoot & _MAX_UINT_64) < _GOLDILOCKS_PRIME_FIELD) &&
            (((newStateRoot >> 64) & _MAX_UINT_64) < _GOLDILOCKS_PRIME_FIELD) &&
            (((newStateRoot >> 128) & _MAX_UINT_64) <
                _GOLDILOCKS_PRIME_FIELD) &&
            ((newStateRoot >> 192) < _GOLDILOCKS_PRIME_FIELD)
        ) {
            return true;
        } else {
            return false;
        }
    }
}
