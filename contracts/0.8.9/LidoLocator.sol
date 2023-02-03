// SPDX-FileCopyrightText: 2021 Lido <info@lido.fi>

// SPDX-License-Identifier: GPL-3.0

/* See contracts/COMPILERS.md */
pragma solidity 0.8.9;

import {ILidoLocator} from "../common/interfaces/ILidoLocator.sol";

/**
 * @title LidoLocator
 * @notice Service locator for Lido Mainnet
 */
contract LidoLocator is ILidoLocator {
    function getLido() external pure returns(address) {
        return 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84; 
    }

    function getDepositSecurityModule() external pure returns (address) {
        return 0x710B3303fB508a84F10793c1106e32bE873C24cd; 
    }

    function getELRewardsVault() external pure returns (address) {
        return 0x388C818CA8B9251b393131C08a736A67ccB19297; 
    }

    function getOracle() external pure returns (address) {
        return 0x442af784A788A5bd6F42A01Ebe9F287a871243fb; 
    }

    function getCompositePostRebaseBeaconReceiver() external pure returns (address) {
        return 0x55a7E1cbD678d9EbD50c7d69Dc75203B0dBdD431; 
    }

    function getSafetyNetsRegistry() external pure returns (address) {
        return 0x1111111111111111111111111111111111111111; // placeholder
    }

    function getSelfOwnedStETHBurner() external pure returns (address) {
        return 0xB280E33812c0B09353180e92e27b8AD399B07f26; 
    }

    function getStakingRouter() external pure returns (address) {
        return 0x2222222222222222222222222222222222222222; // placeholder
    }

    function getTreasury() external pure returns (address) {
        return 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c; 
    }

    function getWithdrawalQueue() external pure returns (address) {
        return 0x3333333333333333333333333333333333333333; // placeholder
    }

    function getWithdrawalVault() external pure returns (address) {
        return 0x4444444444444444444444444444444444444444; // placeholder
    }

}
