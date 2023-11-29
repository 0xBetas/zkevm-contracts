/* eslint-disable no-await-in-loop, no-use-before-define, no-lonely-if */
/* eslint-disable no-console, no-inner-declarations, no-undef, import/no-unresolved */
import {expect} from "chai";
import path = require("path");
import fs = require("fs");

import * as dotenv from "dotenv";
dotenv.config({path: path.resolve(__dirname, "../../.env")});
import {ethers, upgrades} from "hardhat";
import {HardhatEthersSigner} from "@nomicfoundation/hardhat-ethers/signers";

const {create2Deployment} = require("../helpers/deployment-helpers");

const pathOutputJson = path.join(__dirname, "./deploy_output.json");
const pathGenesis = path.join(__dirname, "./genesis.json");

const deployParameters = require("./deploy_parameters.json");
const genesis = require("./genesis.json");
const deployOutput = require("./deploy_output.json");
import "../helpers/utils";

import {PolygonRollupManager, PolygonZkEVMV2, PolygonZkEVMBridgeV2} from "../../typechain-types";

async function main() {
    /*
     * Check deploy parameters
     * Check that every necessary parameter is fullfilled
     */
    const mandatoryDeploymentParameters = [
        "realVerifier",
        "trustedSequencerURL",
        "networkName",
        "description",
        "trustedSequencer",
        "chainID",
        "adminZkEVM",
        "forkID",
        "consensusContract",
    ];

    for (const parameterName of mandatoryDeploymentParameters) {
        if (deployParameters[parameterName] === undefined || deployParameters[parameterName] === "") {
            throw new Error(`Missing parameter: ${parameterName}`);
        }
    }

    const {
        realVerifier,
        trustedSequencerURL,
        networkName,
        description,
        trustedSequencer,
        chainID,
        adminZkEVM,
        forkID,
        consensusContract,
    } = deployParameters;

    const supportedConensus = [
        "PolygonZkEVMEtrog",
        "PolygonZkEVMV2",
        "PolygonDataComittee",
        "PolygonDataComitteeEtrog",
    ];

    if (!supportedConensus.includes(consensusContract)) {
        throw new Error(`Consensus contract not supported, supported contracts are: ${supportedConensus}`);
    }

    // Load provider
    let currentProvider = ethers.provider;
    if (deployParameters.multiplierGas || deployParameters.maxFeePerGas) {
        if (process.env.HARDHAT_NETWORK !== "hardhat") {
            currentProvider = ethers.getDefaultProvider(
                `https://${process.env.HARDHAT_NETWORK}.infura.io/v3/${process.env.INFURA_PROJECT_ID}`
            ) as any;
            if (deployParameters.maxPriorityFeePerGas && deployParameters.maxFeePerGas) {
                console.log(
                    `Hardcoded gas used: MaxPriority${deployParameters.maxPriorityFeePerGas} gwei, MaxFee${deployParameters.maxFeePerGas} gwei`
                );
                const FEE_DATA = new ethers.FeeData(
                    null,
                    ethers.parseUnits(deployParameters.maxFeePerGas, "gwei"),
                    ethers.parseUnits(deployParameters.maxPriorityFeePerGas, "gwei")
                );

                currentProvider.getFeeData = async () => FEE_DATA;
            } else {
                console.log("Multiplier gas used: ", deployParameters.multiplierGas);
                async function overrideFeeData() {
                    const feedata = await ethers.provider.getFeeData();
                    return new ethers.FeeData(
                        null,
                        ((feedata.maxFeePerGas as bigint) * BigInt(deployParameters.multiplierGas)) / 1000n,
                        ((feedata.maxPriorityFeePerGas as bigint) * BigInt(deployParameters.multiplierGas)) / 1000n
                    );
                }
                currentProvider.getFeeData = overrideFeeData;
            }
        }
    }

    // Load deployer
    let deployer;
    if (deployParameters.deployerPvtKey) {
        deployer = new ethers.Wallet(deployParameters.deployerPvtKey, currentProvider);
    } else if (process.env.MNEMONIC) {
        deployer = ethers.HDNodeWallet.fromMnemonic(
            ethers.Mnemonic.fromPhrase(process.env.MNEMONIC),
            "m/44'/60'/0'/0/0"
        ).connect(currentProvider);
    } else {
        [deployer] = await ethers.getSigners();
    }

    // Load Rollup manager
    const PolgonRollupManagerFactory = await ethers.getContractFactory("PolygonRollupManager", deployer);
    const rollupManagerContract = PolgonRollupManagerFactory.attach(
        deployOutput.polygonRollupManager
    ) as PolygonRollupManager;

    let verifierContract;
    if (realVerifier === true) {
        const VerifierRollup = await ethers.getContractFactory("FflonkVerifier", deployer);
        verifierContract = await VerifierRollup.deploy();
        await verifierContract.waitForDeployment();
    } else {
        const VerifierRollupHelperFactory = await ethers.getContractFactory("VerifierRollupHelperMock", deployer);
        verifierContract = await VerifierRollupHelperFactory.deploy();
        await verifierContract.waitForDeployment();
    }
    console.log("#######################\n");
    console.log("Verifier deployed to:", verifierContract.target);

    // Since it's a mock deployment deployer has all the rights
    const ADD_ROLLUP_TYPE_ROLE = ethers.id("ADD_ROLLUP_TYPE_ROLE");
    const CREATE_ROLLUP_ROLE = ethers.id("CREATE_ROLLUP_ROLE");

    // Check role:
    if ((await rollupManagerContract.hasRole(ADD_ROLLUP_TYPE_ROLE, deployer.address)) == false)
        await rollupManagerContract.grantRole(ADD_ROLLUP_TYPE_ROLE, deployer.address);

    if ((await rollupManagerContract.hasRole(CREATE_ROLLUP_ROLE, deployer.address)) == false)
        await rollupManagerContract.grantRole(CREATE_ROLLUP_ROLE, deployer.address);

    // Create consensus implementation
    const PolygonconsensusFactory = (await ethers.getContractFactory(consensusContract, deployer)) as any;
    const PolygonconsensusContract = await PolygonconsensusFactory.deploy(
        deployOutput.polygonZkEVMGlobalExitRootAddress,
        deployOutput.polTokenAddress,
        deployOutput.polygonZkEVMBridgeAddress,
        deployOutput.polygonRollupManager
    );
    await PolygonconsensusContract.waitForDeployment();

    // Add a new rollup type with timelock
    const rollupCompatibilityID = 0;
    await (
        await rollupManagerContract.addNewRollupType(
            PolygonconsensusContract.target,
            verifierContract.target,
            forkID,
            rollupCompatibilityID,
            genesis.root,
            description
        )
    ).wait();

    console.log("#######################\n");
    console.log("Added new Rollup Type deployed");
    const newRollupTypeID = await rollupManagerContract.rollupTypeCount();

    let gasTokenAddress, gasTokenNetwork, gasTokenMetadata;

    if (
        deployParameters.gasTokenAddress &&
        deployParameters.gasTokenAddress != "" &&
        deployParameters.gasTokenAddress != ethers.ZeroAddress
    ) {
        // Get bridge instance
        const bridgeFactory = await ethers.getContractFactory("PolygonZkEVMBridgeV2", deployer);
        const polygonZkEVMBridgeContract = bridgeFactory.attach(
            deployOutput.polygonZkEVMBridgeAddress
        ) as PolygonZkEVMBridgeV2;

        // Get token metadata
        gasTokenMetadata = await polygonZkEVMBridgeContract.getTokenMetadata(deployParameters.gasTokenAddress);

        const wrappedData = await polygonZkEVMBridgeContract.wrappedTokenToTokenInfo(deployParameters.gasTokenAddress);
        if (wrappedData.originNetwork != 0n) {
            // Wrapped token
            gasTokenAddress = wrappedData.originTokenAddress;
            gasTokenNetwork = wrappedData.originNetwork;
        } else {
            // Mainnet token
            gasTokenAddress = deployParameters.gasTokenAddress;
            gasTokenNetwork = 0n;
        }
    } else {
        gasTokenAddress = ethers.ZeroAddress;
        gasTokenNetwork = 0;
        gasTokenMetadata = "0x";
    }

    const newZKEVMAddress = ethers.getCreateAddress({
        from: rollupManagerContract.target as string,
        nonce: await currentProvider.getTransactionCount(rollupManagerContract.target),
    });

    // Create new rollup
    const txDeployRollup = await rollupManagerContract.createNewRollup(
        newRollupTypeID,
        chainID,
        adminZkEVM,
        trustedSequencer,
        gasTokenAddress,
        trustedSequencerURL,
        networkName
    );

    const receipt = (await txDeployRollup.wait()) as any;
    const timestampReceipt = (await receipt?.getBlock())?.timestamp;
    const rollupID = await rollupManagerContract.chainIDToRollupID(chainID);

    console.log("#######################\n");
    console.log("Created new Rollup:", newZKEVMAddress);

    // Assert admin address
    expect(await upgrades.erc1967.getAdminAddress(newZKEVMAddress)).to.be.equal(rollupManagerContract.target);
    expect(await upgrades.erc1967.getImplementationAddress(newZKEVMAddress)).to.be.equal(
        PolygonconsensusContract.target
    );

    // Search added global exit root on the logs
    let globalExitRoot;
    for (const log of receipt?.logs) {
        if (log.address == newZKEVMAddress) {
            const parsedLog = PolygonconsensusFactory.interface.parseLog(log);
            if (parsedLog != null && parsedLog.name == "InitialSequenceBatches") {
                globalExitRoot = parsedLog.args.lastGlobalExitRoot;
            }
        }
    }

    deployOutput.genesis = genesis.root;
    deployOutput.newZKEVMAddress = newZKEVMAddress;
    deployOutput.verifierAddress = verifierContract.target;

    // Add the first batch of the created rollup
    const newZKEVMContract = (await PolygonconsensusFactory.attach(newZKEVMAddress)) as PolygonZkEVMV2;
    const batchData = {
        transactions: await newZKEVMContract.generateInitializeTransaction(
            rollupID,
            gasTokenAddress,
            gasTokenNetwork,
            gasTokenMetadata as any
        ),
        globalExitRoot: globalExitRoot,
        timestamp: timestampReceipt,
        sequencer: trustedSequencer,
    };
    genesis.firstBatchData = batchData;

    fs.writeFileSync(pathOutputJson, JSON.stringify(deployOutput, null, 1));
    fs.writeFileSync(pathGenesis, JSON.stringify(genesis, null, 1));
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
