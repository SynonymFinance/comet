import { task } from 'hardhat/config';

function toWormholeFormat(address: string): string {
  // remove 0x prefix, pad 24 zeros on the left and return with 0x prefix
  return '0x' + address.slice(2).padStart(64, '0');
}

const NETWORK_CONFIGS = {
  arbitrum: {
    chainId: 23,
    wormholeTunnel: '0x0ED850DC162aaC0dcFf3D4e8D7145eECde24a8E6',
    weth: '0x82aF49447D8a07e3bd95BD0d56f35241523fBab1',
    usdc: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831',
  },
  mainnet: {
    chainId: 2,
    wormholeTunnel: '0x54C767A5198FDcA089112026285F333C0fA14599',
    weth: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
    usdc: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
  },
  optimism: {
    chainId: 24,
    wormholeTunnel: '0xa9F5B7131b59E768ae4EB085a7E57efB904279e1',
    weth: '0x4200000000000000000000000000000000000006',
    usdc: '0x0b2c639c533813f4aa9d7837caf62653d097ff85',
  }
};

task('deploy-syno-bridge', 'Deploy SynoBridge')
  .setAction(async (params, hre) => {
    const network = hre.network.name;
    if (!NETWORK_CONFIGS[network]) {
      throw new Error(`Network ${network} not supported`);
    }

    const [deployer] = await hre.ethers.getSigners();

    const config = NETWORK_CONFIGS[network];

    const SynoBridge = await hre.ethers.getContractFactory('SynoBridge');
    const synoBridge = await SynoBridge.deploy(
      await deployer.getAddress(),
      config.wormholeTunnel,
      config.weth,
    );
    await synoBridge.deployed();
    console.log(`SynoBridge deployed to ${synoBridge.address}`);

    console.log('Verifying SynoBridge...');
    await hre.run('verify:verify', {
      address: synoBridge.address,
      constructorArguments: [await deployer.getAddress(), config.wormholeTunnel, config.weth],
    });
  });

task('link-syno-bridge', 'Link SynoBridge to another instance')
  .addParam('bridge', 'The address of the that is being linked')
  .addParam('chainId', 'The chain ID of the bridge to link to')
  .addParam('targetBridge', 'The address of the SynoBridge to link to')
  .setAction(async (params, hre) => {
    const [admin] = await hre.ethers.getSigners();
    const bridge = await hre.ethers.getContractAt('SynoBridge', params.bridge);
    const tx = await bridge.connect(admin).setSynoBridge(params.chainId, toWormholeFormat(params.targetBridge));
    await tx.wait();
    console.log(`SynoBridge linked to ${params.targetBridge} on chain ${params.chainId}`);
  });
