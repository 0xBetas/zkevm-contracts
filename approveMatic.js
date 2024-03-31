const provider = ethers.getDefaultProvider("http://localhost:8845"); // set Geth Goerli RPC node
const privateKey = ""; // From wallet.txt Trusted Sequencer prvkey
const wallet = new ethers.Wallet(privateKey, provider);

const maticTokenFactory = await ethers.getContractFactory(
  "ERC20PermitMock",
  provider
);
maticTokenContract = maticTokenFactory.attach(""); // From ~/zkevm-contracts/deployments/goerli_*/deploy_output.json maticTokenAddress
maticTokenContractWallet = maticTokenContract.connect(wallet);
await maticTokenContractWallet.approve("", ethers.utils.parseEther("100.0")); // From ~/zkevm-contracts/deployments/goerli_*/deploy_output.json polygonZkEVMAddress
