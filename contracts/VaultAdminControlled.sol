// SPDX-License-Identifier: MIT
pragma solidity ^0.8.1;


/* [import-internal] */
import "./interface/IVaultAdminControlled.sol";
import "./Vault.sol";


contract VaultAdminControlled is
	Vault,
	IVaultAdminControlled
{
	/* [state-variable] */
	mapping (uint256 => WithdrawalRequestAdminData) _widrawalRequestAdminData;


	/* [constructor] */
	constructor (
		address admin,
		uint256 requiredForVotes_,
		uint256 withdrawalDelayMinutes_,
		address[] memory voters
	)
		Vault(requiredForVotes_, withdrawalDelayMinutes_, voters)
	{
		// Set up the default admin role
		_setupRole(DEFAULT_ADMIN_ROLE, admin);
	}


	function _deleteWithdrawalRequest(uint256 withdrawalRequestId)
		override(Vault)
		internal
	{
		// [super]
		super._deleteWithdrawalRequest(withdrawalRequestId);

		// [delete] `_widrawalRequestAdminData` value
		delete _widrawalRequestAdminData[withdrawalRequestId];
	}
	

	function createWithdrawalRequest(
		address to,
		address tokenAddress,
		uint256 amount
	)
		override(Vault, IVault)
		public
		onlyRole(VOTER_ROLE)
		returns (uint256)
	{
		// [super]
		uint256 withdrawalRequestId = super.createWithdrawalRequest(
			to,
			tokenAddress,
			amount
		);

		_widrawalRequestAdminData[withdrawalRequestId].paused = false;
		_widrawalRequestAdminData[withdrawalRequestId].accelerated = false;

		return withdrawalRequestId;
	}

	function processWithdrawalRequests(uint256 withdrawalRequestId)
		override(Vault, IVault)
		public
	{
		// [require] Required signatures to be met
		require(
			_withdrawalRequest[withdrawalRequestId].forVoteCount >= requiredForVotes,
			"Not enough signatures"
		);

		// [require] WithdrawalRequest time delay passed OR accelerated
		require(
			block.timestamp - _withdrawalRequest[withdrawalRequestId].lastImpactfulVoteTime >= SafeMath.mul(withdrawalDelayMinutes, 60) ||
			_widrawalRequestAdminData[withdrawalRequestId].accelerated,
			"Not enough time has passed & not accelerated"
		);

		// [require] WithdrawalRequest NOT paused
		require(!_widrawalRequestAdminData[withdrawalRequestId].paused, "Paused");

		// [call][internal]
		_processWithdrawalRequest(withdrawalRequestId);
	}


	/* [restriction][AccessControlEnumerable] DEFAULT_ADMIN_ROLE */
	// @inheritdoc IVaultAdminControlled
	function updateRequiredForVotes(uint256 newRequiredForVotes)
		public
		onlyRole(DEFAULT_ADMIN_ROLE)
		returns (bool, uint256)
	{
		// [require] `newRequiredForVotes` <= VOTER_ROLE Member Count
		require(
			newRequiredForVotes <= getRoleMemberCount(VOTER_ROLE),
			"Invalid `newRequiredForVotes`"
		);

		// [update]
		requiredForVotes = newRequiredForVotes;

		// [emit]
		emit UpdatedRequiredForVotes(requiredForVotes);

		return (true, requiredForVotes);
	}

	// @inheritdoc IVaultAdminControlled
	function addVoter(address voter)
		public
		onlyRole(DEFAULT_ADMIN_ROLE)
		returns (bool, address)
	{
		// [add] Voter to `AccessControl._roles` as VOTER_ROLE
		_setupRole(VOTER_ROLE, voter);

		// [emit]
		emit VoterAdded(voter);

		return (true, voter);
	}

	// @inheritdoc IVaultAdminControlled
	function removeVoter(address voter)
		public
		onlyRole(DEFAULT_ADMIN_ROLE)
		returns (bool, address)
	{
		// [remove] Voter with VOTER_ROLE from `AccessControl._roles`
		_revokeRole(VOTER_ROLE, voter);

		// [emit]
		emit VoterRemoved(voter);

		return (true, voter);
	}

	// @inheritdoc IVaultAdminControlled
	function updateWithdrawalDelayMinutes(uint256 newWithdrawalDelayMinutes)
		public
		onlyRole(DEFAULT_ADMIN_ROLE)
		returns (bool, uint256)
	{
		// [require] newWithdrawalDelayMinutes is greater than 0
		require(newWithdrawalDelayMinutes >= 0, "Invalid newWithdrawalDelayMinutes");

		// [update] `withdrawalDelayMinutes` to new value
		withdrawalDelayMinutes = newWithdrawalDelayMinutes;

		// [emit]
		emit UpdatedWithdrawalDelayMinutes(withdrawalDelayMinutes);

		return (true, withdrawalDelayMinutes);
	}

	// @inheritdoc IVaultAdminControlled
	function toggleWithdrawalRequestPause(uint256 withdrawalRequestId)
		public
		onlyRole(DEFAULT_ADMIN_ROLE)
		validWithdrawalRequest(withdrawalRequestId)
		returns (bool, uint256)
	{
		// [update] `_withdrawalRequestPaused`
		_widrawalRequestAdminData[withdrawalRequestId].paused = !_widrawalRequestAdminData[
			withdrawalRequestId
		].paused;

		// [emit]
		emit ToggledWithdrawalRequestPaused(
			_widrawalRequestAdminData[withdrawalRequestId].paused
		);

		return (true, withdrawalRequestId);
	}

	// @inheritdoc IVaultAdminControlled
	function deleteWithdrawalRequest(uint256 withdrawalRequestId)
		public
		onlyRole(DEFAULT_ADMIN_ROLE)
		validWithdrawalRequest(withdrawalRequestId)
		returns (bool)
	{
		// [call][internal]
		_deleteWithdrawalRequest(withdrawalRequestId);

		return true;
	}
}
