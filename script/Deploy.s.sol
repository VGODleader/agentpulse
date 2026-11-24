// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {AgentPulse} from "../src/AgentPulse.sol";

contract Deploy is Script {
    /// @dev Agent ID (SPACE ID Agent ID) on BNB Smart Chain mainnet.
    address public constant AGENT_ID_MAINNET = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    function run() external returns (AgentPulse deployed) {
        vm.startBroadcast();
        deployed = new AgentPulse(AGENT_ID_MAINNET);
        vm.stopBroadcast();
    }
}
