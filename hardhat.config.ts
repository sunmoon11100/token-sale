import "@nomicfoundation/hardhat-ledger";
import "@nomicfoundation/hardhat-toolbox";
import "@openzeppelin/hardhat-upgrades";
import "hardhat-deploy";
import type { HardhatUserConfig } from "hardhat/config";
import { vars } from "hardhat/config";
import type { NetworkUserConfig } from "hardhat/types";

import "./tasks/accounts";
import "./tasks/deploy";

// Run 'npx hardhat vars setup' to see the list of variables that need to be set

const privateKey: string = vars.get("PRIVATE_KEY");
const infuraApiKey: string = vars.get("INFURA_API_KEY");

const chainIds = {
  "base-mainnet": 8453,
  "base-sepolia": 84532,
  coston: 16,
  coston2: 114,
  flare: 14,
  songbird: 19,
  "arbitrum-mainnet": 42161,
  avalanche: 43114,
  bsc: 56,
  ganache: 1337,
  hardhat: 31337,
  mainnet: 1,
  "optimism-mainnet": 10,
  "polygon-mainnet": 137,
  "polygon-mumbai": 80001,
  sepolia: 11155111,
};

function getChainConfig(chain: keyof typeof chainIds): NetworkUserConfig {
  let jsonRpcUrl: string;
  switch (chain) {
    case "base-mainnet":
      jsonRpcUrl = "https://mainnet.base.org";
      break;
    case "base-sepolia":
      jsonRpcUrl = "https://sepolia.base.org";
      break;
    case "coston":
      jsonRpcUrl = "https://coston-api.flare.network/ext/bc/C/rpc";
      break;
    case "coston2":
      jsonRpcUrl = "https://coston2-api.flare.network/ext/bc/C/rpc";
      break;
    case "flare":
      jsonRpcUrl = "https://flare-api.flare.network/ext/bc/C/rpc";
      break;
    case "songbird":
      jsonRpcUrl = "https://songbird-api.flare.network/ext/bc/C/rpc";
      break;
    case "avalanche":
      jsonRpcUrl = "https://api.avax.network/ext/bc/C/rpc";
      break;
    case "bsc":
      jsonRpcUrl = "https://bsc-dataseed1.binance.org";
      break;
    default:
      jsonRpcUrl = "https://" + chain + ".infura.io/v3/" + infuraApiKey;
  }
  return {
    accounts: privateKey !== undefined ? [privateKey] : [],
    chainId: chainIds[chain],
    url: jsonRpcUrl,
  };
}

const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
  namedAccounts: {
    deployer: 0,
  },
  etherscan: {
    apiKey: {
      coston2: "flare", // API key is not needed, but we need to provide a value
      arbitrumOne: vars.get("ARBISCAN_API_KEY", ""),
      avalanche: vars.get("SNOWTRACE_API_KEY", ""),
      bsc: vars.get("BSCSCAN_API_KEY", ""),
      mainnet: vars.get("ETHERSCAN_API_KEY", ""),
      optimisticEthereum: vars.get("OPTIMISM_API_KEY", ""),
      polygon: vars.get("POLYGONSCAN_API_KEY", ""),
      polygonMumbai: vars.get("POLYGONSCAN_API_KEY", ""),
      sepolia: vars.get("ETHERSCAN_API_KEY", ""),
      base: vars.get("ETHERSCAN_API_KEY", ""),
    },
    customChains: [
      {
        network: "coston2",
        chainId: 114,
        urls: {
          apiURL: "https://api.routescan.io/v2/network/testnet/evm/114/etherscan",
          browserURL: "https://coston2.testnet.flarescan.com",
        },
      },
    ],
  },
  gasReporter: {
    currency: "USD",
    enabled: !!process.env.REPORT_GAS,
    excludeContracts: [],
    src: "./contracts",
  },
  networks: {
    hardhat: {
      chainId: chainIds.hardhat,
    },
    ganache: {
      chainId: chainIds.ganache,
      url: "http://localhost:8545",
    },
    "base-mainnet": {
      ...getChainConfig("base-mainnet"),
      gasPrice: 1000000000,
      ledgerAccounts: ["0x650FC72a15AC564A504741693830b1e32b2df83d"],
      verify: {
        etherscan: {
          apiUrl: "https://api.basescan.org",
          apiKey: vars.get("ETHERSCAN_API_KEY", ""),
        },
      },
    },
    "base-sepolia": {
      ...getChainConfig("base-sepolia"),
      gasPrice: 1000000000,
      verify: {
        etherscan: {
          apiUrl: "https://api-sepolia.basescan.org",
          apiKey: vars.get("ETHERSCAN_API_KEY", ""),
        },
      },
    },
    coston: getChainConfig("coston"),
    coston2: getChainConfig("coston2"),
    flare: getChainConfig("flare"),
    songbird: getChainConfig("songbird"),
    arbitrum: getChainConfig("arbitrum-mainnet"),
    avalanche: getChainConfig("avalanche"),
    bsc: getChainConfig("bsc"),
    mainnet: getChainConfig("mainnet"),
    optimism: getChainConfig("optimism-mainnet"),
    "polygon-mainnet": getChainConfig("polygon-mainnet"),
    "polygon-mumbai": getChainConfig("polygon-mumbai"),
    sepolia: getChainConfig("sepolia"),
  },
  paths: {
    artifacts: "./artifacts",
    cache: "./cache",
    sources: "./contracts",
    tests: "./test",
  },
  solidity: {
    version: "0.8.18",
    settings: {
      metadata: {
        // Not including the metadata hash
        // https://github.com/paulrberg/hardhat-template/issues/31
        bytecodeHash: "none",
      },
      // Disable the optimizer when debugging
      // https://hardhat.org/hardhat-network/#solidity-optimizer-support
      optimizer: {
        enabled: true,
        runs: 800,
      },
    },
  },
  sourcify: {
    enabled: true,
  },
  typechain: {
    outDir: "types",
    target: "ethers-v6",
  },
};

export default config;
