// SPDX-License-Identifier: MIT
pragma solidity ^0.8.1;


/* [import] */
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/* [import-internal] */
import "./interface/IVault.sol";


/**
* @title Vault
*/
contract Vault is
	AccessControlEnumerable,
	IVault
{
	/* [USING] */
	using SafeERC20 for IERC20;


	/* [state-variable] */
	// [public][constant]
	bytes32 public constant VOTER_ROLE = keccak256("VOTER_ROLE");

	// [public]
	uint256 public requiredForVotes;
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
		uint256 requiredForVotes_,
		uint256 withdrawalDelayMinutes_,
		address[] memory voters
	)
	{
		// Initialize WithdrawalRequestId
		_withdrawalRequestId = 0;

		requiredForVotes = requiredForVotes_;

		// Set delay (in minutes)
		withdrawalDelayMinutes = withdrawalDelayMinutes_;

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


	/** Note [restriction][internal] */

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

	/**
	* @notice Process WithdrawalRequest
	*
	* @dev [restriction][internal]
	*
	* @dev 
	*
	* @param withdrawalRequestId {uint256}
	*
	* Emits: `TokensWithdrawn`
	*/
	function _processWithdrawalRequest(uint256 withdrawalRequestId)
		internal
	{
		// Create temporary variable
		WithdrawalRequest memory wr = _withdrawalRequest[withdrawalRequestId];
		
		// [ERC20-transfer] Specified amount of tokens to recipient
		IERC20(wr.token).safeTransfer(wr.to, wr.amount);

		// [decrement] `_tokenBalance`
		_tokenBalance[wr.token] -= wr.amount;

		// [emit]
		emit TokensWithdrawn(msg.sender, wr.to, wr.amount);

		// [call]
		_deleteWithdrawalRequest(withdrawalRequestId);
	}


	/** NOTE [restriction][AccessControlEnumerable] VOTER_ROLE */

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
			forVoteCount: 0,
			againstVoteCount: 0,
			lastImpactfulVoteTime: block.timestamp
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
			}
		}

		// [require] It is msg.sender's (voter's) first vote
		require(!voted, "You have already casted a vote for this WithdrawalRequest");

		if (vote)
		{
			// [update] `_withdrawalRequest` → [increment] For count
			_withdrawalRequest[withdrawalRequestId].forVoteCount++;

			// If required signatures met
			if (
				_withdrawalRequest[withdrawalRequestId].forVoteCount >= requiredForVotes
			)
			{
				// [emit]
				emit WithdrawalRequestReadyToBeProccessed(withdrawalRequestId);
			}
		}
		else
		{
			// [update] `_withdrawalRequest` → [increment] Against count
			_withdrawalRequest[withdrawalRequestId].againstVoteCount++;
		}

		// [emit]
		emit VoterVoted(withdrawalRequestId, msg.sender, vote);

		// [update] `_withdrawalRequestVotedVoters` → Mark voter has voted
		_withdrawalRequestVotedVoters[withdrawalRequestId].push(msg.sender);

		// If the required signatures has not yet been reached..
		if (_withdrawalRequest[withdrawalRequestId].forVoteCount < requiredForVotes)
		{
			// [update] lastImpactfulVoteTime timestamp
			_withdrawalRequest[withdrawalRequestId].lastImpactfulVoteTime = block.timestamp;
		}

		return (
			vote,
			_withdrawalRequest[withdrawalRequestId].forVoteCount,
			_withdrawalRequest[withdrawalRequestId].againstVoteCount,
			_withdrawalRequest[withdrawalRequestId].lastImpactfulVoteTime
		);
	}

	/// @inheritdoc IVault
	function processWithdrawalRequests(uint256 withdrawalRequestId)
		public
		onlyRole(VOTER_ROLE)
		validWithdrawalRequest(withdrawalRequestId)
	{
		// [require] Required signatures to be met
		require(
			_withdrawalRequest[withdrawalRequestId].forVoteCount >= requiredForVotes,
			"Not enough for votes"
		);

		// [require] WithdrawalRequest time delay passed OR accelerated
		require(
			block.timestamp - _withdrawalRequest[withdrawalRequestId].lastImpactfulVoteTime >= SafeMath.mul(withdrawalDelayMinutes, 60),
			"Not enough time has passed"
		);
		
		// [call][internal]
		_processWithdrawalRequest(withdrawalRequestId);
	}


	/** NOTE [!restriction] */
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
	function withdrawalRequestVotedVoters(uint256 withdrawalRequestId)
		view
		public
		returns (address[] memory)
	{
		return _withdrawalRequestVotedVoters[withdrawalRequestId];
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
}