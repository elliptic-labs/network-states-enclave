// SPDX-License-Identifier: MIT
pragma solidity >=0.8.21;

/* Autogenerated file. Do not edit manually. */

import { Move } from "common/MoveInputs.sol";
import { Groth16Proof } from "common/Groth16Proof.sol";
import { VirtualInputs } from "common/VirtualInputs.sol";
import { Signature } from "common/Signature.sol";

/**
 * @title IMoveSystem
 * @dev This interface is automatically generated from the corresponding system contract. Do not edit manually.
 */
interface IMoveSystem {
  function move(
    Move memory moveParams,
    Groth16Proof memory moveProof,
    VirtualInputs memory virtualInputs,
    Groth16Proof memory virtualProof,
    Signature memory sig
  ) external;

  function getCurrentInterval() external view returns (uint256);

  function getCityCenterTroops(uint24 cityId) external view returns (uint32);
}
