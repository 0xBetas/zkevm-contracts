const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');

describe('Emergency mode test', () => {
    let deployer;
    let trustedAggregator;
    let trustedSequencer;
    let admin;

    let verifierContract;
    let bridgeContract;
    let proofOfEfficiencyContract;
    let maticTokenContract;
    let globalExitRootManager;

    const maticTokenName = 'Matic Token';
    const maticTokenSymbol = 'MATIC';
    const maticTokenInitialBalance = ethers.utils.parseEther('20000000');

    const genesisRoot = '0x0000000000000000000000000000000000000000000000000000000000000001';

    const networkIDMainnet = 0;
    const allowForcebatches = true;
    const urlSequencer = 'http://zkevm-json-rpc:8123';
    const chainID = 1000;
    const networkName = 'zkevm';
    const pendingStateTimeoutDefault = 10;
    const trustedAggregatorTimeoutDefault = 10;

    beforeEach('Deploy contract', async () => {
        // load signers
        [deployer, trustedAggregator, trustedSequencer, admin] = await ethers.getSigners();

        // deploy mock verifier
        const VerifierRollupHelperFactory = await ethers.getContractFactory(
            'VerifierRollupHelperMock',
        );
        verifierContract = await VerifierRollupHelperFactory.deploy();

        // deploy MATIC
        const maticTokenFactory = await ethers.getContractFactory('ERC20PermitMock');
        maticTokenContract = await maticTokenFactory.deploy(
            maticTokenName,
            maticTokenSymbol,
            deployer.address,
            maticTokenInitialBalance,
        );
        await maticTokenContract.deployed();

        // deploy global exit root manager
        const globalExitRootManagerFactory = await ethers.getContractFactory('GlobalExitRootManager');
        globalExitRootManager = await upgrades.deployProxy(globalExitRootManagerFactory, [], { initializer: false });

        // deploy bridge
        const bridgeFactory = await ethers.getContractFactory('Bridge');
        bridgeContract = await upgrades.deployProxy(bridgeFactory, [], { initializer: false });

        // deploy PoE
        const ProofOfEfficiencyFactory = await ethers.getContractFactory('ProofOfEfficiencyMock');
        proofOfEfficiencyContract = await upgrades.deployProxy(ProofOfEfficiencyFactory, [], { initializer: false });

        await globalExitRootManager.initialize(proofOfEfficiencyContract.address, bridgeContract.address);
        await bridgeContract.initialize(networkIDMainnet, globalExitRootManager.address, proofOfEfficiencyContract.address);
        await proofOfEfficiencyContract.initialize(
            globalExitRootManager.address,
            maticTokenContract.address,
            verifierContract.address,
            bridgeContract.address,
            {
                admin: admin.address,
                chainID,
                trustedSequencer: trustedSequencer.address,
                pendingStateTimeout: pendingStateTimeoutDefault,
                forceBatchAllowed: allowForcebatches,
                trustedAggregator: trustedAggregator.address,
                trustedAggregatorTimeout: trustedAggregatorTimeoutDefault,
            },
            genesisRoot,
            urlSequencer,
            networkName,
        );

        // fund sequencer address with Matic tokens
        await maticTokenContract.transfer(trustedSequencer.address, ethers.utils.parseEther('100'));
    });

    it('should activate emergency mode', async () => {
        // Check isEmergencyState
        expect(await proofOfEfficiencyContract.isEmergencyState()).to.be.equal(false);
        expect(await bridgeContract.isEmergencyState()).to.be.equal(false);

        // Set isEmergencyState
        await expect(proofOfEfficiencyContract.connect(admin).activateEmergencyState(1))
            .to.be.revertedWith('ProofOfEfficiency::activateEmergencyState: Batch not sequenced or not end of sequence');

        await expect(bridgeContract.connect(deployer).activateEmergencyState())
            .to.be.revertedWith('ProofOfEfficiency::onlyProofOfEfficiency: only Proof of Efficiency contract');

        await expect(proofOfEfficiencyContract.activateEmergencyState(0))
            .to.emit(proofOfEfficiencyContract, 'EmergencyStateActivated')
            .to.emit(bridgeContract, 'EmergencyStateActivated');

        expect(await proofOfEfficiencyContract.isEmergencyState()).to.be.equal(true);
        expect(await bridgeContract.isEmergencyState()).to.be.equal(true);

        // Once in emergency state no sequenceBatches/forceBatches can be done
        const l2txData = '0x123456';
        const maticAmount = await proofOfEfficiencyContract.getCurrentBatchFee();
        const currentTimestamp = (await ethers.provider.getBlock()).timestamp;

        const sequence = {
            transactions: l2txData,
            globalExitRoot: ethers.constants.HashZero,
            timestamp: ethers.BigNumber.from(currentTimestamp),
            minForcedTimestamp: 0,
        };

        // revert because emergency state
        await expect(proofOfEfficiencyContract.sequenceBatches([sequence]))
            .to.be.revertedWith('EmergencyManager::ifNotEmergencyState: only if not emergency state');

        // revert because emergency state
        await expect(proofOfEfficiencyContract.sequenceForceBatches([sequence]))
            .to.be.revertedWith('EmergencyManager::ifNotEmergencyState: only if not emergency state');

        // revert because emergency state
        await expect(proofOfEfficiencyContract.forceBatch(l2txData, maticAmount))
            .to.be.revertedWith('EmergencyManager::ifNotEmergencyState: only if not emergency state');

        // trustedAggregator forge the batch
        const newLocalExitRoot = '0x0000000000000000000000000000000000000000000000000000000000000001';
        const newStateRoot = '0x0000000000000000000000000000000000000000000000000000000000000001';
        const numBatch = (await proofOfEfficiencyContract.lastVerifiedBatch()).toNumber() + 1;
        const proofA = ['0', '0'];
        const proofB = [
            ['0', '0'],
            ['0', '0'],
        ];
        const proofC = ['0', '0'];
        const pendingStateNum = 0;

        await expect(
            proofOfEfficiencyContract.connect(trustedAggregator).verifyBatches(
                pendingStateNum,
                numBatch - 1,
                numBatch,
                newLocalExitRoot,
                newStateRoot,
                proofA,
                proofB,
                proofC,
            ),
        ).to.be.revertedWith('EmergencyManager::ifNotEmergencyState: only if not emergency state');

        // Check bridge no bridge is in emergency state also
        const tokenAddress = ethers.constants.AddressZero;
        const amount = ethers.utils.parseEther('10');
        const destinationNetwork = 1;
        const destinationAddress = deployer.address;

        await expect(bridgeContract.bridgeAsset(
            tokenAddress,
            destinationNetwork,
            destinationAddress,
            amount,
            '0x',
        )).to.be.revertedWith('EmergencyManager::ifNotEmergencyState: only if not emergency state');

        await expect(bridgeContract.bridgeMessage(
            destinationNetwork,
            destinationAddress,
            '0x',
        )).to.be.revertedWith('EmergencyManager::ifNotEmergencyState: only if not emergency state');

        const proof = [ethers.constants.HashZero, ethers.constants.HashZero];
        const index = 0;
        const root = ethers.constants.HashZero;

        await expect(bridgeContract.claimAsset(
            proof,
            index,
            root,
            root,
            0,
            tokenAddress,
            destinationNetwork,
            destinationAddress,
            amount,
            '0x',
        )).to.be.revertedWith('EmergencyManager::ifNotEmergencyState: only if not emergency state');

        await expect(bridgeContract.claimMessage(
            proof,
            index,
            root,
            root,
            0,
            tokenAddress,
            destinationNetwork,
            destinationAddress,
            amount,
            '0x',
        )).to.be.revertedWith('EmergencyManager::ifNotEmergencyState: only if not emergency state');

        // Emergency council should deactivate emergency mode
        await expect(proofOfEfficiencyContract.activateEmergencyState(0))
            .to.be.revertedWith('EmergencyManager::ifNotEmergencyState: only if not emergency state');

        await expect(bridgeContract.connect(deployer).deactivateEmergencyState())
            .to.be.revertedWith('ProofOfEfficiency::onlyProofOfEfficiency: only Proof of Efficiency contract');

        await expect(proofOfEfficiencyContract.deactivateEmergencyState())
            .to.be.revertedWith('ProofOfEfficiency::onlyAdmin: only admin');

        await expect(proofOfEfficiencyContract.connect(admin).deactivateEmergencyState())
            .to.emit(proofOfEfficiencyContract, 'EmergencyStateDeactivated')
            .to.emit(bridgeContract, 'EmergencyStateDeactivated');

        // Check isEmergencyState
        expect(await proofOfEfficiencyContract.isEmergencyState()).to.be.equal(false);
        expect(await bridgeContract.isEmergencyState()).to.be.equal(false);

        /*
         * Continue normal flow
         * Approve tokens
         */
        await expect(
            maticTokenContract.connect(trustedSequencer).approve(proofOfEfficiencyContract.address, maticAmount),
        ).to.emit(maticTokenContract, 'Approval');

        const lastBatchSequenced = await proofOfEfficiencyContract.lastBatchSequenced();
        // Sequence Batches
        await expect(proofOfEfficiencyContract.connect(trustedSequencer).sequenceBatches([sequence]))
            .to.emit(proofOfEfficiencyContract, 'SequenceBatches')
            .withArgs(lastBatchSequenced + 1);

        // trustedAggregator forge the batch
        const initialAggregatorMatic = await maticTokenContract.balanceOf(
            trustedAggregator.address,
        );
        await ethers.provider.send('evm_increaseTime', [trustedAggregatorTimeoutDefault]); // evm_setNextBlockTimestamp

        // Verify batch
        await expect(
            proofOfEfficiencyContract.connect(trustedAggregator).verifyBatches(
                pendingStateNum,
                numBatch - 1,
                numBatch,
                newLocalExitRoot,
                newStateRoot,
                proofA,
                proofB,
                proofC,
            ),
        ).to.emit(proofOfEfficiencyContract, 'VerifyBatches')
            .withArgs(numBatch, newStateRoot, trustedAggregator.address);

        const finalAggregatorMatic = await maticTokenContract.balanceOf(
            trustedAggregator.address,
        );
        expect(finalAggregatorMatic).to.equal(
            ethers.BigNumber.from(initialAggregatorMatic).add(ethers.BigNumber.from(maticAmount)),
        );

        // Finally enter in emergency mode again proving distinc state
        const finalPendingStateNum = 1;

        await expect(
            proofOfEfficiencyContract.connect(trustedAggregator).proveNonDeterministicPendingState(
                pendingStateNum,
                finalPendingStateNum,
                numBatch - 1,
                numBatch - 1,
                newLocalExitRoot,
                newStateRoot,
                proofA,
                proofB,
                proofC,
            ),
        ).to.be.revertedWith('ProofOfEfficiency::proveNonDeterministicPendingState: finalNewBatch must be equal than currentLastVerifiedBatch');

        await expect(
            proofOfEfficiencyContract.connect(trustedAggregator).proveNonDeterministicPendingState(
                pendingStateNum,
                finalPendingStateNum,
                numBatch - 1,
                numBatch + 1,
                newLocalExitRoot,
                newStateRoot,
                proofA,
                proofB,
                proofC,
            ),
        ).to.be.revertedWith('ProofOfEfficiency::proveNonDeterministicPendingState: finalNewBatch must be equal than currentLastVerifiedBatch');

        const newStateRootDistinct = '0x0000000000000000000000000000000000000000000000000000000000000002';

        await expect(
            proofOfEfficiencyContract.proveNonDeterministicPendingState(
                pendingStateNum,
                finalPendingStateNum,
                numBatch - 1,
                numBatch,
                newLocalExitRoot,
                newStateRootDistinct,
                proofA,
                proofB,
                proofC,
            ),
        ).to.emit(proofOfEfficiencyContract, 'ProveNonDeterministicPendingState').withArgs(newStateRoot, newStateRootDistinct)
            .to.emit(proofOfEfficiencyContract, 'EmergencyStateActivated')
            .to.emit(bridgeContract, 'EmergencyStateActivated');

        // Check emergency state is active
        expect(await proofOfEfficiencyContract.isEmergencyState()).to.be.equal(true);
        expect(await bridgeContract.isEmergencyState()).to.be.equal(true);
    });
});
