// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "./interfaces/IVerifierRollup.sol";
import "./interfaces/IGlobalExitRootManager.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/IBridge.sol";
import "./lib/EmergencyManager.sol";

/**
 * Contract responsible for managing the states and the updates of L2 network
 * There will be a trusted sequencer, which is able to send transactions.
 * Any user can force some transaction and the sequencer will have a timeout to add them in the queue
 * THe sequenced state is deterministic and can be precalculated before it's actually verified by a zkProof
 * The aggregators will be able to actually verify the sequenced state with zkProofs and be to perform withdrawals from L2 network
 * To enter and exit of the L2 network will be used a Bridge smart contract that will be deployed in both networks
 */
contract ProofOfEfficiency is
    Initializable,
    OwnableUpgradeable,
    EmergencyManager
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /**
     * @notice Struct which will be used to call sequenceBatches
     * @param transactions L2 ethereum transactions EIP-155 or pre-EIP-155 with signature:
     * EIP-155: rlp(nonce, gasprice, gasLimit, to, value, data, chainid, 0, 0,) || v || r || s
     * pre-EIP-155: rlp(nonce, gasprice, gasLimit, to, value, data) || v || r || s
     * @param globalExitRoot Global exit root of the batch
     * @param timestamp Sequenced timestamp of the batch
     * @param minForcedTimestamp Minimum timestamp of the force batch data, empty when non forced batch
     */
    struct BatchData {
        bytes transactions;
        bytes32 globalExitRoot;
        uint64 timestamp;
        uint64 minForcedTimestamp;
    }

    /**
     * @notice Struct which will be used to call sequenceForceBatches
     * @param transactions L2 ethereum transactions EIP-155 or pre-EIP-155 with signature:
     * EIP-155: rlp(nonce, gasprice, gasLimit, to, value, data, chainid, 0, 0,) || v || r || s
     * pre-EIP-155: rlp(nonce, gasprice, gasLimit, to, value, data) || v || r || s
     * @param globalExitRoot Global exit root of the batch
     * @param minForcedTimestamp Indicates the minimum sequenced timestamp of the batch
     */
    struct ForcedBatchData {
        bytes transactions;
        bytes32 globalExitRoot;
        uint64 minForcedTimestamp;
    }

    /**
     * @notice Struct which will stored for every batch sequence
     * @param accInputHash Hash chain that contains all the information to process a batch:
     *  keccak256(bytes32 oldAccInputHash, keccak256(bytes transactions), bytes32 globalExitRoot, uint64 timestamp, address seqAddress)
     * @param sequencedTimestamp Sequenced timestamp
     */
    struct SequencedBatchData {
        bytes32 accInputHash;
        uint64 sequencedTimestamp;
    }

    /**
     * @notice Struct which will be used to call sequenceForceBatches
     * @param transactions L2 ethereum transactions EIP-155 or pre-EIP-155 with signature:
     * EIP-155: rlp(nonce, gasprice, gasLimit, to, value, data, chainid, 0, 0,) || v || r || s
     * pre-EIP-155: rlp(nonce, gasprice, gasLimit, to, value, data) || v || r || s
     * @param globalExitRoot Global exit root of the batch
     * @param minForcedTimestamp Indicates the minimum sequenced timestamp of the batch
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

    // trusted sequencer prover Fee
    uint256 public constant TRUSTED_SEQUENCER_FEE = 0.1 ether; // TODO should be defined

    // Max batch byte length
    // Max keccaks circuit = (2**23 / 158418) * 9 = 468
    // Bytes per keccak = 136
    // Minimum Static keccaks batch = 4
    // Max bytes allowed = (468 - 4) * 136 = 63104 bytes - 1 byte padding
    // Rounded to 60000 bytes
    uint256 public constant MAX_BATCH_LENGTH = 60000;

    // Force batch timeout
    uint64 public constant FORCE_BATCH_TIMEOUT = 7 days;

    // Byte length of the sha256 that will be used as a input of the snark
    // SHA256(oldStateRoot, newStateRoot, oldAccInputHash, newAccInputHash, newLocalExitRoot, oldNumBatch, newNumBatch, chainID, aggrAddress)
    // 8 Fields * 8 Bytes (Stark input in Field Array form) * 5 (hashes), + 8 bytes * 3 (oldNumBatch, newNumBatch, chainID) + 20 bytes (aggrAddress)
    uint256 internal constant _SNARK_SHA_BYTES = 364;

    // If the time that a batch remains sequenced exceeds this timeout, the contract enters in emergency mode
    uint64 public constant HALT_AGGREGATION_TIMEOUT = 1 weeks;

    // Maximum trusted aggregator timeout that can be set
    uint64 public constant MAX_TRUSTED_AGGREGATOR_TIMEOUT = 1 weeks;

    // MATIC token address
    IERC20Upgradeable public matic;

    // Queue of forced batches with their associated data
    // ForceBatchNum --> hashedForcedBatchData
    // hashedForcedBatchData: hash containing the necessary information to force a batch:
    // keccak256(keccak256(bytes transactions), bytes32 globalExitRoot, unint64 minTimestamp)
    mapping(uint64 => bytes32) public forcedBatches;

    // Queue of batches that defines the virtual state
    // SequenceBatchNum --> SequencedBatchData
    mapping(uint64 => SequencedBatchData) public sequencedBatches;

    // Storage Slot //

    // Last sequenced timestamp
    uint64 public lastTimestamp;

    // Last batch sent by the sequencers
    uint64 public lastBatchSequenced;

    // Last forced batch included in the sequence
    uint64 public lastForceBatchSequenced;

    // Last forced batch
    uint64 public lastForceBatch;

    // Storage Slot //

    // Last batch verified by the aggregators
    uint64 public lastVerifiedBatch;

    // Trusted sequencer address
    address public trustedSequencer;

    // Storage Slot //

    // Trusted aggregator address
    address public trustedAggregator;

    // Timestamp of the last trusted aggregation
    uint64 public lastTrustedAggregationTime;

    // Storage Slot //

    // Timestamp until the aggregation will be open to anyone
    uint64 public openAggregationUntil;

    // Rollup verifier interface
    IVerifierRollup public rollupVerifier;

    // Storage Slot //

    // L2 chain identifier
    uint64 public chainID;

    // Global Exit Root interface
    IGlobalExitRootManager public globalExitRootManager;

    // Indicates whether the force batch functionality is available
    bool public forceBatchAllowed;

    // State root mapping
    // BatchNum --> state root
    mapping(uint64 => bytes32) public batchNumToStateRoot;

    // Trusted sequencer URL
    string public trustedSequencerURL;

    // L2 network name
    string public networkName;

    // Security council, only can take action if extraordinary conditions happens
    address public securityCouncil;

    // Bridge Address
    IBridge public bridgeAddress;

    // Pending state, once the pendingStateTimeout has passed, the pending state becomes consolidated
    // pendingStateNumber --> PendingState
    mapping(uint256 => PendingState) public pendingStateTransitions;

    // Last pending state
    uint64 public lastPendingStateNum;

    // Pending state timeout
    uint64 public pendingStateTimeout;

    // Pending state timeout
    uint64 public currentPendingStateNum;

    // Trusted aggregator timeout, if a batch is not aggregated in this time frame,
    // everyone can aggregate that batch
    uint64 public trustedAggregatorTimeout;

    /**
     * @dev Emitted when the trusted sequencer sends a new batch of transactions
     */
    event SequenceBatches(uint64 indexed numBatch);

    /**
     * @dev Emitted when a batch is forced
     */
    event ForceBatch(
        uint64 indexed forceBatchNum,
        bytes32 lastGlobalExitRoot,
        address sequencer,
        bytes transactions
    );

    /**
     * @dev Emitted when forced batches are sequenced by not the trusted sequencer
     */
    event SequenceForceBatches(uint64 indexed numBatch);

    /**
     * @dev Emitted when a aggregator verifies a new batch
     */
    event VerifyBatches(
        uint64 indexed numBatch,
        bytes32 stateRoot,
        address indexed aggregator
    );

    /**
     * @dev Emitted when a trusted sequencer update his address
     */
    event SetTrustedSequencer(address newTrustedSequencer);

    /**
     * @dev Emitted when a trusted sequencer update the forcebatch boolean
     */
    event SetForceBatchAllowed(bool newForceBatchAllowed);

    /**
     * @dev Emitted when a trusted sequencer update his URL
     */
    event SetTrustedSequencerURL(string newTrustedSequencerURL);

    /**
     * @dev Emitted when security council update his address
     */
    event SetSecurityCouncil(address newSecurityCouncil);

    /**
     * @dev Emitted when a trusted aggregator update the trusted aggregator timeout
     */
    event SetTrustedAggregatorTimeout(uint64 newTrustedAggregatorTimeout);

    /**
     * @dev Emitted when a trusted aggregator update or renounce his address
     */
    event SetTrustedAggregator(address newTrustedAggregator);

    /**
     * @dev Emitted when is proved a different state given the same batches
     */
    event ProveNonDeterministicState(
        bytes32 storedStateRoot,
        bytes32 provedStateRoot
    );

    /**
     * @param _globalExitRootManager global exit root manager address
     * @param _matic MATIC token address
     * @param _rollupVerifier rollup verifier address
     * @param genesisRoot rollup genesis root
     * @param _trustedSequencer trusted sequencer address
     * @param _forceBatchAllowed indicates wheather the force batch functionality is available
     * @param _trustedSequencerURL trusted sequencer URL
     * @param _chainID L2 chainID
     * @param _networkName L2 network name
     * @param _bridgeAddress bridge address
     * @param _securityCouncil security council
     */
    function initialize(
        IGlobalExitRootManager _globalExitRootManager,
        IERC20Upgradeable _matic,
        IVerifierRollup _rollupVerifier,
        bytes32 genesisRoot,
        address _trustedSequencer,
        bool _forceBatchAllowed,
        string memory _trustedSequencerURL,
        uint64 _chainID,
        string memory _networkName,
        IBridge _bridgeAddress,
        address _securityCouncil,
        address _trustedAggregator,
        uint64 trustedAggregatorTimeout
    ) public initializer {
        globalExitRootManager = _globalExitRootManager;
        matic = _matic;
        rollupVerifier = _rollupVerifier;
        batchNumToStateRoot[0] = genesisRoot;
        trustedSequencer = _trustedSequencer;
        forceBatchAllowed = _forceBatchAllowed;
        trustedSequencerURL = _trustedSequencerURL;
        chainID = _chainID;
        networkName = _networkName;
        bridgeAddress = _bridgeAddress;
        securityCouncil = _securityCouncil;
        trustedAggregator = _trustedAggregator;
        lastTrustedAggregationTime = uint64(block.timestamp);
        trustedAggregatorTimeout = trustedAggregatorTimeout;

        // Initialize OZ contracts
        __Ownable_init_unchained();
    }

    modifier onlySecurityCouncil() {
        require(
            securityCouncil == msg.sender,
            "ProofOfEfficiency::onlySecurityCouncil: only security council"
        );
        _;
    }

    modifier onlyTrustedSequencer() {
        require(
            trustedSequencer == msg.sender,
            "ProofOfEfficiency::onlyTrustedSequencer: only trusted sequencer"
        );
        _;
    }

    modifier onlyTrustedAgggregator() {
        require(
            trustedAggregator == msg.sender,
            "ProofOfEfficiency::onlyTrustedAgggregator: only trusted Aggregator"
        );
        _;
    }

    // Only for the current version
    modifier isForceBatchAllowed() {
        require(
            forceBatchAllowed == true,
            "ProofOfEfficiency::isForceBatchAllowed: only if force batch is available"
        );
        _;
    }

    /**
     * @notice Allows a sequencer to send multiple batches
     * @param batches Struct array which the necessary data to append new batces ot the sequence
     */
    function sequenceBatches(
        BatchData[] memory batches
    ) public ifNotEmergencyState onlyTrustedSequencer {
        uint256 batchesNum = batches.length;
        require(
            batchesNum > 0,
            "ProofOfEfficiency::sequenceBatches: At least must sequence 1 batch"
        );
        // Store storage variables in memory, to save gas, because will be overrided multiple times
        uint64 currentTimestamp = lastTimestamp;
        uint64 currentBatchSequenced = lastBatchSequenced;
        uint64 currentLastForceBatchSequenced = lastForceBatchSequenced;
        bytes32 currentAccInputHash = sequencedBatches[currentBatchSequenced]
            .accInputHash;

        for (uint256 i = 0; i < batchesNum; i++) {
            // Load current sequence
            BatchData memory currentBatch = batches[i];

            // Check if it's a forced batch
            if (currentBatch.minForcedTimestamp > 0) {
                currentLastForceBatchSequenced++;

                // Check forced data matches
                bytes32 hashedForcedBatchData = keccak256(
                    abi.encodePacked(
                        keccak256(currentBatch.transactions),
                        currentBatch.globalExitRoot,
                        currentBatch.minForcedTimestamp
                    )
                );

                require(
                    hashedForcedBatchData ==
                        forcedBatches[currentLastForceBatchSequenced],
                    "ProofOfEfficiency::sequenceBatches: Forced batches data must match"
                );

                // Check timestamp is bigger than min timestamp
                require(
                    currentBatch.timestamp >= currentBatch.minForcedTimestamp,
                    "ProofOfEfficiency::sequenceBatches: Forced batches timestamp must be bigger or equal than min"
                );
            } else {
                // Check global exit root exist, and proper batch length, this checks are already done in the force Batches call
                require(
                    currentBatch.globalExitRoot == bytes32(0) ||
                        globalExitRootManager.globalExitRootMap(
                            currentBatch.globalExitRoot
                        ) !=
                        0,
                    "ProofOfEfficiency::sequenceBatches: Global exit root must exist"
                );

                require(
                    currentBatch.transactions.length < MAX_BATCH_LENGTH,
                    "ProofOfEfficiency::sequenceBatches: Transactions bytes overflow"
                );
            }

            // Check Batch timestamps are correct
            require(
                currentBatch.timestamp >= currentTimestamp &&
                    currentBatch.timestamp <= block.timestamp,
                "ProofOfEfficiency::sequenceBatches: Timestamp must be inside range"
            );

            // Calculate next acc input hash
            currentAccInputHash = keccak256(
                abi.encodePacked(
                    currentAccInputHash,
                    keccak256(currentBatch.transactions),
                    currentBatch.globalExitRoot,
                    currentBatch.timestamp,
                    msg.sender
                )
            );

            // Update currentBatchSequenced
            currentBatchSequenced++;

            // Update timestamp
            currentTimestamp = currentBatch.timestamp;
        }

        // Sanity check, should not be unreachable
        require(
            currentLastForceBatchSequenced <= lastForceBatch,
            "ProofOfEfficiency::sequenceBatches: Force batches overflow"
        );

        uint256 nonForcedBatchesSequenced = batchesNum -
            (currentLastForceBatchSequenced - lastForceBatchSequenced);

        // Store back the storage variables
        lastTimestamp = currentTimestamp;
        lastBatchSequenced = currentBatchSequenced;
        lastForceBatchSequenced = currentLastForceBatchSequenced;
        sequencedBatches[currentBatchSequenced] = SequencedBatchData({
            accInputHash: currentAccInputHash,
            sequencedTimestamp: uint64(block.timestamp)
        });

        // Pay collateral for every batch submitted
        matic.safeTransferFrom(
            msg.sender,
            address(this),
            TRUSTED_SEQUENCER_FEE * nonForcedBatchesSequenced
        );

        emit SequenceBatches(lastBatchSequenced);
    }

    /**
     * @notice Allows an aggregator to verify multiple batches
     * @param initNumBatch Batch which the aggregator starts the verification
     * @param finalNewBatch Last batch aggregator intends to verify
     * @param newLocalExitRoot  New local exit root once the batch is processed
     * @param newStateRoot New State root once the batch is processed
     * @param proofA zk-snark input
     * @param proofB zk-snark input
     * @param proofC zk-snark input
     */
    function verifyBatches(
        uint64 pendingStateNum,
        uint64 initNumBatch,
        uint64 finalNewBatch,
        bytes32 newLocalExitRoot,
        bytes32 newStateRoot,
        uint256[2] calldata proofA,
        uint256[2][2] calldata proofB,
        uint256[2] calldata proofC
    ) public ifNotEmergencyState {
        if (
            trustedAggregator == address(0) ||
            msg.sender == trustedAggregator ||
            trustedAggregatorTimeout == 0
        ) {
            _verifyAndConsolidateState(
                pendingStateNum,
                initNumBatch,
                finalNewBatch,
                newLocalExitRoot,
                newStateRoot,
                proofA,
                proofB,
                proofC
            );
        } else {
            SequencedBatchData storage oldSequencedBatchData = sequencedBatches[
                initNumBatch
            ];
            SequencedBatchData storage newSequencedBatchData = sequencedBatches[
                finalNewBatch
            ];

            bytes32 oldStateRoot;
            uint64 currentLastVerifiedBatch;

            // Use pending state if any, otherwise use consolidate state
            if (pendingStateNum != 0) {
                require(
                    pendingStateNum <= lastPendingStateNum,
                    "ProofOfEfficiency::verifyBatches: pendingStateNum must be less or equal than lastPendingStateNum"
                );
                // Use pending state
                PendingState storage lastPendingState = pendingStateTransitions[
                    lastPendingStateNum
                ];

                currentLastVerifiedBatch = lastPendingState.lastVerifiedBatch;
                oldStateRoot = lastPendingState.stateRoot;
            } else {
                // Use consolidated state
                require(
                    batchNumToStateRoot[initNumBatch] != bytes32(0),
                    "ProofOfEfficiency::verifyBatches: initNumBatch state root does not exist"
                );

                currentLastVerifiedBatch = lastVerifiedBatch;
                oldStateRoot = batchNumToStateRoot[initNumBatch];
            }

            // Assert init and final batch
            require(
                initNumBatch <= currentLastVerifiedBatch,
                "ProofOfEfficiency::verifyBatches: initNumBatch must be less or equal than currentLastVerifiedBatch"
            );

            require(
                finalNewBatch > currentLastVerifiedBatch,
                "ProofOfEfficiency::verifyBatches: finalNewBatch must be bigger than currentLastVerifiedBatch"
            );

            // Get snark bytes
            bytes memory snarkHashBytes = getInputSnarkBytes(
                initNumBatch,
                finalNewBatch,
                newLocalExitRoot,
                oldStateRoot,
                newStateRoot
            );

            // Calulate the snark input
            uint256 inputSnark = uint256(sha256(snarkHashBytes)) % _RFIELD;

            // Verify proof
            require(
                rollupVerifier.verifyProof(
                    proofA,
                    proofB,
                    proofC,
                    [inputSnark]
                ),
                "ProofOfEfficiency::verifyBatches: INVALID_PROOF"
            );

            // Get MATIC reward
            matic.safeTransfer(
                msg.sender,
                calculateRewardPerBatch() *
                    (finalNewBatch - currentLastVerifiedBatch)
            );

            // Update state or pending state
            if (msg.sender == trustedAggregator) {
                // Update state
                lastVerifiedBatch = finalNewBatch;
                batchNumToStateRoot[finalNewBatch] = newStateRoot;

                // Clean pending state
                lastPendingStateNum = 0;
                currentPendingStateNum = 0;

                // Interact with globalExitRoot
                globalExitRootManager.updateExitRoot(newLocalExitRoot);
            } else {
                _consolidatePendingState();

                // Update pending state
                lastPendingStateNum++;
                pendingStateTransitions[lastPendingStateNum] = PendingState({
                    timestamp: uint64(block.timestamp),
                    lastVerifiedBatch: finalNewBatch,
                    exitRoot: newLocalExitRoot,
                    stateRoot: newStateRoot
                });
            }

            emit VerifyBatches(finalNewBatch, newStateRoot, msg.sender);
        }
    }

    function _verifyAndConsolidateState(
        uint64 pendingStateNum,
        uint64 initNumBatch,
        uint64 finalNewBatch,
        bytes32 newLocalExitRoot,
        bytes32 newStateRoot,
        uint256[2] calldata proofA,
        uint256[2][2] calldata proofB,
        uint256[2] calldata proofC
    ) internal {
        bytes32 oldStateRoot;
        uint64 currentLastVerifiedBatch;

        // Use pending state if especified, otherwise use consolidate state
        if (pendingStateNum != 0) {
            // Use pending state
            require(
                pendingStateNum <= lastPendingStateNum,
                "ProofOfEfficiency::verifyBatches: pendingStateNum must be less or equal than lastPendingStateNum"
            );

            require(
                pendingStateNum > currentPendingStateNum,
                "ProofOfEfficiency::verifyBatches: pendingStateNum must bigger than currentPendingStateNum"
            );

            // Check pending choosen pending state
            PendingState storage lastPendingState = pendingStateTransitions[
                pendingStateNum
            ];

            // Check if pending state hasn't exceed the timeout
            require(
                block.timestamp - lastPendingState.timestamp <=
                    pendingStateTimeout,
                "ProofOfEfficiency::verifyBatches: pendingStateTimeout exceeded"
            );
            currentLastVerifiedBatch = lastPendingState.lastVerifiedBatch;
            oldStateRoot = lastPendingState.stateRoot;
        } else {
            // Use consolidated state
            require(
                batchNumToStateRoot[initNumBatch] != bytes32(0),
                "ProofOfEfficiency::verifyBatches: initNumBatch state root does not exist"
            );

            currentLastVerifiedBatch = lastVerifiedBatch;
            oldStateRoot = batchNumToStateRoot[initNumBatch];
        }

        // Assert init and final batch
        require(
            initNumBatch <= currentLastVerifiedBatch,
            "ProofOfEfficiency::verifyBatches: initNumBatch must be less or equal than currentLastVerifiedBatch"
        );

        require(
            finalNewBatch > currentLastVerifiedBatch,
            "ProofOfEfficiency::verifyBatches: finalNewBatch must be bigger than currentLastVerifiedBatch"
        );

        // Get snark bytes
        bytes memory snarkHashBytes = getInputSnarkBytes(
            initNumBatch,
            finalNewBatch,
            newLocalExitRoot,
            oldStateRoot,
            newStateRoot
        );

        // Calulate the snark input
        uint256 inputSnark = uint256(sha256(snarkHashBytes)) % _RFIELD;

        // Verify proof
        require(
            rollupVerifier.verifyProof(proofA, proofB, proofC, [inputSnark]),
            "ProofOfEfficiency::verifyBatches: INVALID_PROOF"
        );

        // Get MATIC reward
        matic.safeTransfer(
            msg.sender,
            calculateRewardPerBatch() *
                (finalNewBatch - currentLastVerifiedBatch)
            // If it's overriding batches everyone "loses" matic
            // Anyway trusted aggregator can damage the system, this is not that problematic
            // last payed batch?
        );

        // Update state
        lastVerifiedBatch = finalNewBatch;
        batchNumToStateRoot[finalNewBatch] = newStateRoot;

        // Clean pending state
        lastPendingStateNum = 0;
        currentPendingStateNum = 0;

        // Interact with globalExitRootManager
        globalExitRootManager.updateExitRoot(newLocalExitRoot);

        emit VerifyBatches(finalNewBatch, newStateRoot, msg.sender);
    }

    /**
     * @notice Internal function to consolidate pending state
     */
    function _consolidatePendingState() public {
        // If trusted aggregator, can consolidate whathever
    }

    /**
     * @notice Allows a sequencer/user to force a batch of L2 transactions.
     * This should be used only in extreme cases where the trusted sequencer does not work as expected
     * @param transactions L2 ethereum transactions EIP-155 or pre-EIP-155 with signature:
     * @param maticAmount Max amount of MATIC tokens that the sender is willing to pay
     */
    function forceBatch(
        bytes memory transactions,
        uint256 maticAmount
    ) public ifNotEmergencyState isForceBatchAllowed {
        // Calculate matic collateral
        uint256 maticFee = calculateBatchFee();

        require(
            maticFee <= maticAmount,
            "ProofOfEfficiency::forceBatch: not enough matic"
        );

        require(
            transactions.length < MAX_BATCH_LENGTH,
            "ProofOfEfficiency::forceBatch: Transactions bytes overflow"
        );

        matic.safeTransferFrom(msg.sender, address(this), maticFee);

        // Get globalExitRoot global exit root
        bytes32 lastGlobalExitRoot = globalExitRootManager
            .getLastGlobalExitRoot();

        // Update forcedBatches mapping
        lastForceBatch++;

        forcedBatches[lastForceBatch] = keccak256(
            abi.encodePacked(
                keccak256(transactions),
                lastGlobalExitRoot,
                uint64(block.timestamp)
            )
        );

        // In order to avoid synch attacks, if the msg.sender is not the origin
        // Add the transaction bytes in the event
        if (msg.sender == tx.origin) {
            emit ForceBatch(lastForceBatch, lastGlobalExitRoot, msg.sender, "");
        } else {
            emit ForceBatch(
                lastForceBatch,
                lastGlobalExitRoot,
                msg.sender,
                transactions
            );
        }
    }

    /**
     * @notice Allows anyone to sequence forced Batches if the trusted sequencer do not have done it in the timeout period
     * @param batches Struct array which the necessary data to append new batces ot the sequence
     */
    function sequenceForceBatches(
        ForcedBatchData[] memory batches
    ) public ifNotEmergencyState isForceBatchAllowed {
        uint256 batchesNum = batches.length;

        require(
            batchesNum > 0,
            "ProofOfEfficiency::sequenceForceBatch: Must force at least 1 batch"
        );

        require(
            lastForceBatchSequenced + batchesNum <= lastForceBatch,
            "ProofOfEfficiency::sequenceForceBatch: Force batch invalid"
        );

        // Store storage variables in memory, to save gas, because will be overrided multiple times
        uint64 currentBatchSequenced = lastBatchSequenced;
        uint64 currentLastForceBatchSequenced = lastForceBatchSequenced;
        bytes32 currentAccInputHash = sequencedBatches[currentBatchSequenced]
            .accInputHash;

        // Sequence force batches
        for (uint256 i = 0; i < batchesNum; i++) {
            // Load current sequence
            ForcedBatchData memory currentBatch = batches[i];
            currentLastForceBatchSequenced++;

            // Check forced data matches
            bytes32 hashedForcedBatchData = keccak256(
                abi.encodePacked(
                    keccak256(currentBatch.transactions),
                    currentBatch.globalExitRoot,
                    currentBatch.minForcedTimestamp
                )
            );

            require(
                hashedForcedBatchData ==
                    forcedBatches[currentLastForceBatchSequenced],
                "ProofOfEfficiency::sequenceForceBatches: Forced batches data must match"
            );

            if (i == (batchesNum - 1)) {
                // The last batch will have the most restrictive timestamp
                require(
                    currentBatch.minForcedTimestamp + FORCE_BATCH_TIMEOUT <=
                        block.timestamp,
                    "ProofOfEfficiency::sequenceForceBatch: Forced batch is not in timeout period"
                );
            }
            // Calculate next acc input hash
            currentAccInputHash = keccak256(
                abi.encodePacked(
                    currentAccInputHash,
                    keccak256(currentBatch.transactions),
                    currentBatch.globalExitRoot,
                    uint64(block.timestamp),
                    msg.sender
                )
            );

            // Update currentBatchSequenced
            currentBatchSequenced++;
        }

        lastTimestamp = uint64(block.timestamp);

        // Store back the storage variables
        lastBatchSequenced = currentBatchSequenced;
        lastForceBatchSequenced = currentLastForceBatchSequenced;
        sequencedBatches[currentBatchSequenced] = SequencedBatchData({
            accInputHash: currentAccInputHash,
            sequencedTimestamp: uint64(block.timestamp)
        });

        emit SequenceForceBatches(lastBatchSequenced);
    }

    /**
     * @notice Allow the current trusted sequencer to set a new trusted sequencer
     * @param newTrustedSequencer Address of the new trusted sequuencer
     */
    function setTrustedSequencer(
        address newTrustedSequencer
    ) public onlyTrustedSequencer {
        trustedSequencer = newTrustedSequencer;

        emit SetTrustedSequencer(newTrustedSequencer);
    }

    /**
     * @notice Allow the current trusted sequencer to allow/disallow the forceBatch functionality
     * @param newForceBatchAllowed Whether is allowed or not the forceBatch functionality
     */
    function setForceBatchAllowed(
        bool newForceBatchAllowed
    ) public onlyTrustedSequencer {
        forceBatchAllowed = newForceBatchAllowed;

        emit SetForceBatchAllowed(newForceBatchAllowed);
    }

    /**
     * @notice Allow the trusted sequencer to set the trusted sequencer URL
     * @param newTrustedSequencerURL URL of trusted sequencer
     */
    function setTrustedSequencerURL(
        string memory newTrustedSequencerURL
    ) public onlyTrustedSequencer {
        trustedSequencerURL = newTrustedSequencerURL;

        emit SetTrustedSequencerURL(newTrustedSequencerURL);
    }

    /**
     * @notice Allow the current security council to set a new security council address
     * @param newSecurityCouncil Address of the new security council
     */
    function setSecurityCouncil(
        address newSecurityCouncil
    ) public onlySecurityCouncil {
        securityCouncil = newSecurityCouncil;

        emit SetSecurityCouncil(newSecurityCouncil);
    }

    /**
     * @notice Allow the current trusted aggregator to set a new trusted aggregator address
     * If address 0 is set, everyone is free to aggregate
     * @param newTrustedAggregator Address of the new trusted aggregator
     */
    function setTrustedAggregator(
        address newTrustedAggregator
    ) public onlyTrustedAgggregator {
        trustedAggregator = newTrustedAggregator;

        emit SetTrustedAggregator(newTrustedAggregator);
    }

    /**
     * @notice Allow the current trusted aggregator to set a new trusted aggregator timeout
     * @param newTrustedAggregatorTimeout Trusted aggreagator timeout
     */
    function setTrustedAggregator(
        uint64 newTrustedAggregatorTimeout
    ) public onlyTrustedAgggregator {
        require(
            trustedAggregatorTimeout <= MAX_TRUSTED_AGGREGATOR_TIMEOUT,
            "ProofOfEfficiency::setTrustedAggregator: exceed max trusted aggregator timeout"
        );
        trustedAggregatorTimeout = newTrustedAggregatorTimeout;

        emit SetTrustedAggregatorTimeout(trustedAggregatorTimeout);
    }

    /**
     * @notice Allows to halt the PoE if its possible to prove a different state root given the same batches
     * @param initNumBatch Batch which the aggregator starts the verification
     * @param finalNewBatch Last batch aggregator intends to verify
     * @param newLocalExitRoot  New local exit root once the batch is processed
     * @param newStateRoot New State root once the batch is processed
     * @param proofA zk-snark input
     * @param proofB zk-snark input
     * @param proofC zk-snark input
     */
    function proveNonDeterministicState(
        uint64 initNumBatch,
        uint64 finalNewBatch,
        bytes32 newLocalExitRoot,
        bytes32 newStateRoot,
        uint256[2] calldata proofA,
        uint256[2][2] calldata proofB,
        uint256[2] calldata proofC
    ) public ifNotEmergencyState {
        require(
            initNumBatch < finalNewBatch,
            "ProofOfEfficiency::proveNonDeterministicState: finalNewBatch must be bigger than initNumBatch"
        );

        require(
            finalNewBatch <= lastVerifiedBatch,
            "ProofOfEfficiency::proveNonDeterministicState: finalNewBatch must be less or equal than lastVerifiedBatch"
        );

        require(
            batchNumToStateRoot[initNumBatch] != bytes32(0),
            "ProofOfEfficiency::proveNonDeterministicState: initNumBatch state root does not exist"
        );

        require(
            batchNumToStateRoot[finalNewBatch] != bytes32(0),
            "ProofOfEfficiency::proveNonDeterministicState: finalNewBatch state root does not exist"
        );

        bytes memory snarkHashBytes = getInputSnarkBytes(
            initNumBatch,
            finalNewBatch,
            newLocalExitRoot,
            newStateRoot
        );

        // Calulate the snark input
        uint256 inputSnark = uint256(sha256(snarkHashBytes)) % _RFIELD;

        // Verify proof
        require(
            rollupVerifier.verifyProof(proofA, proofB, proofC, [inputSnark]),
            "ProofOfEfficiency::proveNonDeterministicState: INVALID_PROOF"
        );

        require(
            batchNumToStateRoot[finalNewBatch] != newStateRoot,
            "ProofOfEfficiency::proveNonDeterministicState: stored root must be different than new state root"
        );

        emit ProveNonDeterministicState(
            batchNumToStateRoot[finalNewBatch],
            newStateRoot
        );

        // Activate emergency state
        _activateEmergencyState();
    }

    /**
     * @notice Function to activate scape hatch, which also enable the emergency mode on both PoE and Bridge contrats
     * Only can be called by the owner in the bootstrap phase, once the owner is renounced, the system
     * can only be put on emergency mode by proving a distinct state root given the same batches
     */
    function activateScapeHatch() external onlyOwner {
        _activateEmergencyState();
    }

    /**
     * @notice Function to deactivate emergency state on both PoE and Bridge contrats
     * Only can be called by the security council
     */
    function deactivateEmergencyState()
        external
        ifEmergencyState
        onlySecurityCouncil
    {
        // Deactivate emergency state on bridge
        bridgeAddress.deactivateEmergencyState();

        // Deactivate emergency state on this contract
        super._deactivateEmergencyState();
    }

    /**
     * @notice Function to calculate the fee that must be payed for every batch
     */
    function calculateBatchFee() public view returns (uint256) {
        return 1 ether * uint256(1 + lastForceBatch - lastForceBatchSequenced);
    }

    /**
     * @notice Function to calculate the reward to verify a single batch
     */
    function calculateRewardPerBatch() public view returns (uint256) {
        uint256 currentBalance = matic.balanceOf(address(this));

        // Total Sequenced Batches = forcedBatches to be sequenced (total forced Batches - sequenced Batches) + sequencedBatches
        // Total Batches to be verified = Total Sequenced Batches - verified Batches
        uint256 totalBatchesToVerify = ((lastForceBatch -
            lastForceBatchSequenced) + lastBatchSequenced) - lastVerifiedBatch;
        return currentBalance / totalBatchesToVerify;
    }

    /**
     * @notice Function to calculate the input snark bytes
     * @param initNumBatch Batch which the aggregator starts teh verification
     * @param finalNewBatch Last batch aggregator intends to verify
     * @param newLocalExitRoot  New local exit root once the batch is processed
     * @param newStateRoot New State root once the batch is processed
     */
    function getInputSnarkBytes(
        uint64 initNumBatch,
        uint64 finalNewBatch,
        bytes32 newLocalExitRoot,
        bytes32 oldStateRoot,
        bytes32 newStateRoot
    ) public view returns (bytes memory) {
        bytes32 oldAccInputHash = sequencedBatches[initNumBatch].accInputHash;
        bytes32 newAccInputHash = sequencedBatches[finalNewBatch].accInputHash;

        require(
            initNumBatch == 0 || oldAccInputHash != bytes32(0),
            "ProofOfEfficiency::getInputSnarkBytes: oldAccInputHash does not exist"
        );

        require(
            newAccInputHash != bytes32(0),
            "ProofOfEfficiency::getInputSnarkBytes: newAccInputHash does not exist"
        );

        return
            abi.encodePacked(
                msg.sender,
                oldStateRoot,
                oldAccInputHash,
                initNumBatch,
                chainID,
                newStateRoot,
                newAccInputHash,
                newLocalExitRoot,
                finalNewBatch
            );
    }

    /**
     * @notice Internal function to activate emergency state on both PoE and Bridge contrats
     */
    function _activateEmergencyState() internal override {
        // Activate emergency state on bridge
        bridgeAddress.activateEmergencyState();

        // Activate emergency state on this contract
        super._activateEmergencyState();
    }
}
