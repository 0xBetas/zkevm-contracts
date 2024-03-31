const { ethers } = require('ethers');
const ct = require('./compiled-contracts/PolygonValidiumEtrog.json');

// Connect to Ethereum provider
// const provider = new ethers.JsonRpcProvider('http://172.31.43.24:8545'); // Replace with your provider URL
const provider = new ethers.JsonRpcProvider('http://127.0.0.1:8123'); // Replace with your provider URL

// Contract ABI - Replace with your contract ABI
const contractABI = ct.abi;

// Contract Address - Replace with your contract address
const contractAddress = '0x7bcAccD41C422d04D0dbe8Ea8EAD5ec77D8bB6da';

// Create contract instance
const wallet = new ethers.Wallet("0xfdc5fc171a0a1aed3dd6fbf03b8247535ea9b043175abc66459d651166d4e5b1", provider);

const contract = new ethers.Contract(contractAddress, contractABI, wallet);

// Call a function on the contract
async function callContractFunction() {
  try {
    // Replace 'yourFunctionName' with the name of the function you want to call
    // console.log(contract);
    // const result = await wallet.sendTransaction({
    //   from: '0x1909BD53c9Ee4cd29015961b11f88ce0Facc3b50',
    //   to: '0xCc24754FBC913F7f4AF34F263D3bedC47e230844',
    //   data: '0xdb5b0ed700000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000006605061f00000000000000000000000000000000000000000000000000000000000000010000000000000000000000001909bd53c9ee4cd29015961b11f88ce0facc3b50000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000000015a89be3ee577b3057afd0330f6100fe17e085b6b0829cda51af59866bfcd5baa0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000055f68fa38688ba4dabeabd456abbf9bf329b1f842bcddb9cb4881800fa3dbf92a211f356c8500c9ebb8efa2978d87f64740ccbda996e32ce4e8ff44b8babeb422b1c5b762f8bf782a533258cbbee285520f2d2ffe32b0000000000000000000000'
    // })
    const result = await contract.gasTokenAddress();// This is a call to a function with no parameters
    console.log('Result:', result);
  } catch (error) {
    console.error('Error:', error);
  }
}

callContractFunction();
