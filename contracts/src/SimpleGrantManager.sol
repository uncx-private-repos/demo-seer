/**
 * @authors: [@xyzseer]
 * @reviewers: []
 * @auditors: []
 * @bounties: []
 * @deployments: []
 */

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title SimpleGrantManager
 * @dev A simple grant system using conditional tokens and Reality.eth
 * This bypasses the futarchy complexity and provides direct milestone-based funding
 */
contract SimpleGrantManager {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    /// @dev Conditional Tokens contract
    IConditionalTokens public immutable conditionalTokens;

    /// @dev Reality.eth contract
    IRealityETH_v3_0 public immutable realitio;

    /// @dev Arbitrator for Reality.eth disputes
    address public immutable arbitrator;

    /// @dev Question timeout for Reality.eth
    uint32 public immutable questionTimeout;

    /// @dev Template ID for boolean questions
    uint8 internal constant BOOLEAN_TEMPLATE = 0;

    /// @dev Grant struct to store grant information
    struct Grant {
        IERC20 collateralToken;
        bytes32 conditionId;
        bytes32 questionId;
        uint256 amount;
        address recipient;
        bool resolved;
        string question;
        uint32 deadline;
    }

    /// @dev Mapping from grant ID to grant details
    mapping(bytes32 => Grant) public grants;
    /// @dev Set of all grant IDs for enumeration
    EnumerableSet.Bytes32Set private grantIds;

    /// @dev Events
    event GrantCreated(
        bytes32 indexed grantId,
        string question,
        address indexed recipient,
        uint256 amount,
        bytes32 questionId,
        bytes32 conditionId
    );

    event GrantResolved(bytes32 indexed grantId, bool success, uint256 answer);

    event GrantRecovered(
        bytes32 indexed grantId,
        address indexed provider,
        uint256 amount
    );

    /**
     * @dev Constructor
     * @param _conditionalTokens Conditional Tokens contract address
     * @param _realitio Reality.eth contract address
     * @param _arbitrator Arbitrator address for Reality.eth disputes
     * @param _questionTimeout Question timeout in seconds
     */
    constructor(
        IConditionalTokens _conditionalTokens,
        IRealityETH_v3_0 _realitio,
        address _arbitrator,
        uint32 _questionTimeout
    ) {
        conditionalTokens = _conditionalTokens;
        realitio = _realitio;
        arbitrator = _arbitrator;
        questionTimeout = _questionTimeout;
    }

    /**
     * @dev Creates a new grant with conditional tokens
     * @param question The Reality.eth question (e.g., "Did Team X deliver milestone Y by date Z?")
     * @param collateralToken The token used as collateral (DAI, USDC, etc.)
     * @param amount The grant amount
     * @param recipient The grant recipient address
     * @param deadline The deadline for the milestone (opening time for Reality.eth question)
     * @param minBond Minimum bond for Reality.eth question
     * @return grantId The unique identifier for this grant
     */
    function createGrant(
        string memory question,
        IERC20 collateralToken,
        uint256 amount,
        address recipient,
        uint32 deadline,
        uint256 minBond
    ) external payable returns (bytes32 grantId) {
        require(amount > 0, "Amount must be greater than 0");
        require(recipient != address(0), "Invalid recipient");
        require(deadline > block.timestamp, "Deadline must be in the future");

        // 1. Ask Reality.eth question
        bytes32 questionId = askRealityQuestion(question, deadline, minBond);

        // 2. Prepare conditional tokens condition
        bytes32 conditionId = conditionalTokens.getConditionId(
            address(this), // This contract acts as the oracle
            questionId,
            2 // YES/NO outcomes
        );

        conditionalTokens.prepareCondition(address(this), questionId, 2);

        // 3. Transfer collateral from grant provider to this contract
        collateralToken.transferFrom(msg.sender, address(this), amount);

        // 4. Split collateral into YES/NO tokens
        collateralToken.approve(address(conditionalTokens), amount);

        {
            uint256[] memory partition = new uint256[](2);
            partition[0] = 1; // YES outcome (index 0)
            partition[1] = 2; // NO outcome (index 1)

            conditionalTokens.splitPosition(
                address(collateralToken),
                bytes32(0), // Root position
                conditionId,
                partition,
                amount
            );
        }

        // 5. Transfer YES tokens to recipient
        _transferYesTokens(collateralToken, conditionId, recipient, amount);

        // 6. Store grant information
        grantId = keccak256(abi.encode(questionId, recipient, amount));
        grants[grantId] = Grant({
            collateralToken: collateralToken,
            conditionId: conditionId,
            questionId: questionId,
            amount: amount,
            recipient: recipient,
            resolved: false,
            question: question,
            deadline: deadline
        });

        grantIds.add(grantId);

        emit GrantCreated(
            grantId,
            question,
            recipient,
            amount,
            questionId,
            conditionId
        );

        return grantId;
    }

    function _transferYesTokens(
        IERC20 collateralToken,
        bytes32 conditionId,
        address recipient,
        uint256 amount
    ) internal {
        bytes32 yesCollectionId = conditionalTokens.getCollectionId(
            bytes32(0),
            conditionId,
            1 // YES outcome
        );

        uint256 yesPositionId = conditionalTokens.getPositionId(
            address(collateralToken),
            yesCollectionId
        );

        conditionalTokens.safeTransferFrom(
            address(this),
            recipient,
            yesPositionId,
            amount,
            ""
        );
    }

    /**
     * @dev Resolves a grant based on Reality.eth answer
     * @param grantId The grant to resolve
     */
    function resolveGrant(bytes32 grantId) external {
        Grant storage grant = grants[grantId];
        require(grant.recipient != address(0), "Grant does not exist");
        require(!grant.resolved, "Grant already resolved");

        // Get the answer from Reality.eth
        uint256 answer = uint256(
            realitio.resultForOnceSettled(grant.questionId)
        );

        uint256[] memory payouts = new uint256[](2);

        // For Reality.eth bool: 1 = Yes, 0 = No, 0xffff..ff = Invalid
        if (answer == 1) {
            payouts[0] = 1; // YES outcome gets full payout
            payouts[1] = 0; // NO outcome gets nothing
        } else {
            payouts[0] = 0; // YES outcome gets nothing
            payouts[1] = 1; // NO outcome gets full payout
        }

        // Report payouts to conditional tokens
        conditionalTokens.reportPayouts(grant.questionId, payouts);

        grant.resolved = true;

        emit GrantResolved(grantId, answer == 1, answer);
    }

    /**
     * @dev Allows grant recipient to redeem their YES tokens for collateral
     * @param grantId The grant to redeem
     */
    function redeemGrant(bytes32 grantId) external {
        Grant storage grant = grants[grantId];
        require(grant.resolved, "Grant not yet resolved");

        bytes32 yesCollectionId = conditionalTokens.getCollectionId(
            bytes32(0),
            grant.conditionId,
            1 // YES outcome
        );

        uint256 yesPositionId = conditionalTokens.getPositionId(
            address(grant.collateralToken),
            yesCollectionId
        );

        uint256 balance = conditionalTokens.balanceOf(
            msg.sender,
            yesPositionId
        );
        require(balance > 0, "No YES tokens to redeem");

        // Redeem positions
        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 1; // YES outcome

        conditionalTokens.redeemPositions(
            address(grant.collateralToken),
            bytes32(0), // Root position
            grant.conditionId,
            indexSets
        );
    }

    /**
     * @dev Allows grant provider to recover funds when grant fails
     * @param grantId The grant to recover funds from
     */
    function recoverFailedGrant(bytes32 grantId) external {
        Grant storage grant = grants[grantId];
        require(grant.resolved, "Grant not yet resolved");

        // Check if grant failed (answer != 0)
        uint256 answer = uint256(
            realitio.resultForOnceSettled(grant.questionId)
        );
        require(answer != 0, "Grant succeeded, cannot recover funds");

        bytes32 noCollectionId = conditionalTokens.getCollectionId(
            bytes32(0),
            grant.conditionId,
            2 // NO outcome
        );

        uint256 noPositionId = conditionalTokens.getPositionId(
            address(grant.collateralToken),
            noCollectionId
        );

        uint256 balance = conditionalTokens.balanceOf(
            address(this),
            noPositionId
        );
        require(balance > 0, "No NO tokens to redeem");

        // Redeem NO positions for collateral
        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 2; // NO outcome

        conditionalTokens.redeemPositions(
            address(grant.collateralToken),
            bytes32(0), // Root position
            grant.conditionId,
            indexSets
        );

        // Transfer recovered collateral to grant provider
        uint256 recoveredAmount = grant.collateralToken.balanceOf(
            address(this)
        );
        grant.collateralToken.transfer(msg.sender, recoveredAmount);

        emit GrantRecovered(grantId, msg.sender, recoveredAmount);
    }

    /**
     * @dev Asks a question on Reality.eth
     * @param question The question text
     * @param openingTime The opening time for the question
     * @param minBond The minimum bond for the question
     * @return questionId The Reality.eth question ID
     */
    function askRealityQuestion(
        string memory question,
        uint32 openingTime,
        uint256 minBond
    ) internal returns (bytes32 questionId) {
        // Encode the question with proper format
        string memory encodedQuestion = encodeBooleanQuestion(question);

        bytes32 contentHash = keccak256(
            abi.encodePacked(BOOLEAN_TEMPLATE, openingTime, encodedQuestion)
        );

        questionId = keccak256(
            abi.encodePacked(
                contentHash,
                arbitrator,
                questionTimeout,
                minBond,
                address(realitio),
                address(this),
                uint256(0)
            )
        );

        // If Reality.eth is not deployed (e.g., during unit tests), skip external calls
        if (address(realitio).code.length == 0) {
            return questionId;
        }

        // Check if question already exists
        if (realitio.getTimeout(questionId) != 0) {
            return questionId;
        }

        // Ask the question on Reality.eth
        return
            realitio.askQuestionWithMinBond{value: msg.value}(
                BOOLEAN_TEMPLATE,
                encodedQuestion,
                arbitrator,
                questionTimeout,
                openingTime,
                0, // nonce
                minBond
            );
    }

    /**
     * @dev Encodes a boolean question for Reality.eth
     * @param question The question text
     * @return encodedQuestion The encoded question
     */
    function encodeBooleanQuestion(
        string memory question
    ) internal pure returns (string memory) {
        // Format: "Question text␟category␟language"
        // Using the delimiter character "␟" (U+241F)
        return
            string(
                abi.encodePacked(
                    question,
                    unicode"␟",
                    "grants",
                    unicode"␟",
                    "en"
                )
            );
    }

    /**
     * @dev Gets all grants
     * @return Array of all grant IDs
     */
    function getAllGrants() external view returns (bytes32[] memory) {
        return grantIds.values();
    }

    /**
     * @dev Gets grant count
     * @return Number of grants
     */
    function getGrantCount() external view returns (uint256) {
        return grantIds.length();
    }

    /**
     * @dev Gets grant details
     * @param grantId The grant ID
     * @return Grant details
     */
    function getGrant(bytes32 grantId) external view returns (Grant memory) {
        return grants[grantId];
    }

    // ERC1155 receiver hooks to accept position tokens minted/transferred by ConditionalTokens
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155Received(address,address,uint256,uint256,bytes)"
                )
            );
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"
                )
            );
    }
}
