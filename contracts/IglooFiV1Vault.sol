// SPDX-License-Identifier: MIT
pragma solidity ^0.8.1;


/* [import] */
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./interface/IIglooFiV1Vault.sol";


/**
* @title Igloo Fi V1 Vault
*/
contract IglooFiV1Vault is
	AccessControlEnumerable,
	IVault
{
	/* [using] */
	using SafeERC20 for IERC20;


	/* [state-variable] */
	// [public][constant]
	bytes32 public constant VOTER_ROLE = keccak256("VOTER_ROLE");

	// [public]
	uint256 public requiredApproveVotes;
	uint256 public withdrawalDelayMinutes;
	
	// [internal]
	uint256 internal _withdrawalRequestId;

	// [mapping]
	// Token Contract Address => Balance
	mapping (address => uint256) _tokenBalance;
	// WithdrawalRequestId => WithdrawalRequest
	mapping (uint256 => WithdrawalRequest) _withdrawalRequest;
	// Voter Address => Array of WithdrawalRequest
	mapping (address => uint256[]) _withdrawalRequestByCreator;
	// WithdrawalRequestId => Voted Voter Addresses Array
	mapping (uint256 => address[]) _withdrawalRequestVotedVoters;


	/* [constructor] */
	constructor (
		address admin,
		uint256 _requiredApproveVotes,
		uint256 _withdrawalDelayMinutes,
		address[] memory voters
	)
	{
		// Initialize WithdrawalRequestId
		_withdrawalRequestId = 0;

		// Set DEFAULT_ADMIN_ROLE
		_setupRole(DEFAULT_ADMIN_ROLE, admin);

		requiredApproveVotes = _requiredApproveVotes;
		withdrawalDelayMinutes = _withdrawalDelayMinutes;

		// [for] each voter address..
		for (uint256 i = 0; i < voters.length; i++)
		{
			// [add] Voter to `AccessControl._roles` as VOTER_ROLE
			_setupRole(VOTER_ROLE, voters[i]);
		}
	}


	/* [recieve] */
	receive ()
		external
		payable
	{
		revert(
			"Sending Ether directly to this contract is disabled, please use `depositTokens()` to send tokens into vault"
		);
	}


	/* [fallback] */
	fallback ()
		external
		payable
	{
		revert(
			"Sending Ether directly to this contract is disabled, please use `depositTokens()` to send tokens into vault"
		);
	}


	/* [modifier] */
	modifier validWithdrawalRequest(uint256 withdrawalRequestId) {
		// [require] withdrawalRequestId exists
		require(
			_withdrawalRequest[withdrawalRequestId].creator != address(0),
			"No WithdrawalRequest found"
		);
		
		_;
	}


	/* [function] */
	/**
	* @notice Delete WithdrawalRequest
	*
	* @dev [restriction][internal]
	*
	* @dev [delete] `_withdrawalRequest` value
	*      [delete] `_withdrawalRequestVotedVoters` value
	*      [delete] `_withdrawalRequestByCreator` value
	*
	* @param withdrawalRequestId {uint256}
	*
	* Emits: `DeletedWithdrawalRequest`
	*/
	function _deleteWithdrawalRequest(uint256 withdrawalRequestId)
		internal
	{
		// [delete] `_withdrawalRequest` value
		delete _withdrawalRequest[withdrawalRequestId];

		// [delete] `_withdrawalRequestVotedVoters` value
		delete _withdrawalRequestVotedVoters[withdrawalRequestId];

		for (uint256 i = 0; i < _withdrawalRequestByCreator[_withdrawalRequest[withdrawalRequestId].creator].length; i++)
		{
			if (_withdrawalRequestByCreator[_withdrawalRequest[withdrawalRequestId].creator][i] == withdrawalRequestId)
			{
				// [delete] `_withdrawalRequestByCreator` value
				delete _withdrawalRequestByCreator[_withdrawalRequest[withdrawalRequestId].creator][i];

				break;
			}
		}

		// [emit]
		emit DeletedWithdrawalRequest(withdrawalRequestId);
	}


	/// @inheritdoc IVault
	function tokenBalance(address tokenAddress)
		view
		public
		returns (uint256)
	{
		return _tokenBalance[tokenAddress];
	}

	/// @inheritdoc IVault
	function withdrawalRequest(uint256 withdrawalRequestId)
		view
		public
		returns (WithdrawalRequest memory)
	{
		return _withdrawalRequest[withdrawalRequestId];
	}

	/// @inheritdoc IVault
	function withdrawalRequestByCreator(address creator)
		view
		public
		returns (uint256[] memory)
	{
		return _withdrawalRequestByCreator[creator];
	}

	/// @inheritdoc IVault
	function withdrawalRequestVotedVoters(uint256 withdrawalRequestId)
		view
		public
		returns (address[] memory)
	{
		return _withdrawalRequestVotedVoters[withdrawalRequestId];
	}

	
	/// @inheritdoc IVault
	function depositTokens(address tokenAddress, uint256 amount)
		public
		returns (uint256, uint256)
	{
		// Ensure token is not a null address
		require(
			tokenAddress != address(0),
			"Token address cannot be null"
		);
		
		// Ensure amount is greater than zero
		require(
			amount > 0,
			"Amount must be greater than zero"
		);

		// [ERC20-transfer] Transfer amount from msg.sender to this contract
		IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);

		// [increment] `_tokenBalance`
		_tokenBalance[tokenAddress] += amount;
			
		// [emit]
		emit TokensDeposited(msg.sender, tokenAddress, amount);
		
		return (amount, _tokenBalance[tokenAddress]);
	}
	

	/// @inheritdoc IVault
	function createWithdrawalRequest(
		address to,
		address tokenAddress,
		uint256 amount
	)
		public
		onlyRole(VOTER_ROLE)
		returns (uint256)
	{
		// [require]  The specified amount is available
		require(_tokenBalance[tokenAddress] >= amount, "Insufficient funds");

		// [require] 'to' is a valid Ethereum address
		require(to != address(0), "Invalid `to` address");

		// [increment] `_withdrawalRequestId`
		_withdrawalRequestId++;

		// [add] `_withdrawalRequest` value
		_withdrawalRequest[_withdrawalRequestId] = WithdrawalRequest({
			creator: msg.sender,
			to: to,
			token: tokenAddress,
			amount: amount,
			approveVoteCount: 0,
			denyVoteCount: 0,
			latestRelevantApproveVoteTime: block.timestamp
		});

		// [push-into] `_withdrawalRequestByCreator`
		_withdrawalRequestByCreator[msg.sender].push(_withdrawalRequestId);

		// [emit]
		emit CreatedWithdrawalRequest(_withdrawalRequest[_withdrawalRequestId]);
		
		return _withdrawalRequestId;
	}

	/// @inheritdoc IVault
	function voteOnWithdrawalRequest(uint256 withdrawalRequestId, bool vote)
		public
		onlyRole(VOTER_ROLE)
		validWithdrawalRequest(withdrawalRequestId)
		returns (bool, uint256, uint256, uint256)
	{
		// [init]
		bool voted = false;

		// [for] each voter within WithdrawalRequest
		for (uint256 i = 0; i < _withdrawalRequestVotedVoters[withdrawalRequestId].length; i++)
		{
			if (_withdrawalRequestVotedVoters[withdrawalRequestId][i] == msg.sender)
			{
				// Flag
				voted = true;

				break;
			}
		}

		// [require] It is msg.sender's (voter's) first vote
		require(!voted, "You have already casted a vote for this WithdrawalRequest");

		if (vote)
		{
			// [update] `_withdrawalRequest` → [increment] Approve vote count
			_withdrawalRequest[withdrawalRequestId].approveVoteCount++;

			// If required signatures met..
			if (_withdrawalRequest[withdrawalRequestId].approveVoteCount >= requiredApproveVotes)
			{
				// [emit]
				emit WithdrawalRequestReadyToBeProccessed(withdrawalRequestId);
			}
		}
		else
		{
			// [update] `_withdrawalRequest` → [increment] Deny vote count
			_withdrawalRequest[withdrawalRequestId].denyVoteCount++;
		}

		// [emit]
		emit VoterVoted(withdrawalRequestId, msg.sender, vote);

		// [update] `_withdrawalRequestVotedVoters` → Mark voter has voted
		_withdrawalRequestVotedVoters[withdrawalRequestId].push(msg.sender);

		// If the required signatures has not yet been reached..
		if (_withdrawalRequest[withdrawalRequestId].approveVoteCount < requiredApproveVotes)
		{
			// [update] latestRelevantApproveVoteTime timestamp
			_withdrawalRequest[withdrawalRequestId].latestRelevantApproveVoteTime = block.timestamp;
		}

		return (
			vote,
			_withdrawalRequest[withdrawalRequestId].approveVoteCount,
			_withdrawalRequest[withdrawalRequestId].denyVoteCount,
			_withdrawalRequest[withdrawalRequestId].latestRelevantApproveVoteTime
		);
	}

	/// @inheritdoc IVault
	function processWithdrawalRequests(uint256 withdrawalRequestId)
		public
		onlyRole(VOTER_ROLE)
		validWithdrawalRequest(withdrawalRequestId)
	{
		// Temporary variable
		WithdrawalRequest memory w = _withdrawalRequest[withdrawalRequestId];
		
		// [require] Required signatures to be met
		require(
			w.approveVoteCount >= requiredApproveVotes,
			"Not enough for votes"
		);

		// [require] WithdrawalRequest time delay passed
		require(
			block.timestamp - w.latestRelevantApproveVoteTime >= SafeMath.mul(withdrawalDelayMinutes, 60),
			"Not enough time has passed"
		);

		// [ERC20-transfer] Specified amount of tokens to recipient
		IERC20(w.token).safeTransfer(w.to, w.amount);

		// [decrement] `_tokenBalance`
		_tokenBalance[_withdrawalRequest[withdrawalRequestId].token] -= w.amount;

		// [call][internal]
		_deleteWithdrawalRequest(withdrawalRequestId);

		// [emit]
		emit TokensWithdrawn(msg.sender, w.to, w.amount);
	}
	

	/// @inheritdoc IVaultAdminControlled
	function addVoter(address targetAddress)
		public
		onlyRole(DEFAULT_ADMIN_ROLE)
		returns (address)
	{
		// [add] address to VOTER_ROLE on `AccessControlEnumerable`
		_setupRole(VOTER_ROLE, targetAddress);

		// [emit]
		emit VoterAdded(targetAddress);

		return targetAddress;
	}

	/// @inheritdoc IVaultAdminControlled
	function removeVoter(address voter)
		public
		onlyRole(DEFAULT_ADMIN_ROLE)
		returns (address)
	{
		// [remove] address with VOTER_ROLE on `AccessControlEnumerable`
		_revokeRole(VOTER_ROLE, voter);

		// [emit]
		emit VoterRemoved(voter);

		return voter;
	}

	/// @inheritdoc IVaultAdminControlled
	function updateRequiredApproveVotes(uint256 newRequiredApproveVotes)
		public
		onlyRole(DEFAULT_ADMIN_ROLE)
		returns (uint256)
	{
		// [update]
		requiredApproveVotes = newRequiredApproveVotes;

		// [emit]
		emit UpdatedRequiredApproveVotes(requiredApproveVotes);

		return (requiredApproveVotes);
	}

	/// @inheritdoc IVaultAdminControlled
	function updateWithdrawalDelayMinutes(uint256 newWithdrawalDelayMinutes)
		public
		onlyRole(DEFAULT_ADMIN_ROLE)
		returns (uint256)
	{
		// [require] newWithdrawalDelayMinutes is greater than OR equal to 0
		require(newWithdrawalDelayMinutes >= 0, "Invalid newWithdrawalDelayMinutes");

		// [update] `withdrawalDelayMinutes`
		withdrawalDelayMinutes = newWithdrawalDelayMinutes;

		// [emit]
		emit UpdatedWithdrawalDelayMinutes(withdrawalDelayMinutes);

		return withdrawalDelayMinutes;
	}

	/// @inheritdoc IVaultAdminControlled
	function updateWithdrawalRequestLatestRelevantApproveVoteTime(
		uint256 withdrawalRequestId,
		uint256 latestRelevantApproveVoteTime
	)
		public
		onlyRole(DEFAULT_ADMIN_ROLE)
		validWithdrawalRequest(withdrawalRequestId)
		returns (uint256, uint256)
	{
		// [update] WithdrawalRequest within `_withdrawalRequest`
		_withdrawalRequest[
			withdrawalRequestId
		].latestRelevantApproveVoteTime = latestRelevantApproveVoteTime;

		return (withdrawalRequestId, latestRelevantApproveVoteTime);
	}

	/// @inheritdoc IVaultAdminControlled
	function deleteWithdrawalRequest(uint256 withdrawalRequestId)
		public
		onlyRole(DEFAULT_ADMIN_ROLE)
		validWithdrawalRequest(withdrawalRequestId)
		returns (uint256)
	{
		// [call][internal]
		_deleteWithdrawalRequest(withdrawalRequestId);

		return withdrawalRequestId;
	}
}