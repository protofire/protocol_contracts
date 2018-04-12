
pragma solidity ^0.4.21;

import 'zeppelin-solidity/contracts/math/Math.sol';

import './B0xStorage.sol';
import './B0xProxyContracts.sol';
import '../shared/InternalFunctions.sol';

import '../B0xVault.sol';
import '../oracle/OracleRegistry.sol';
import '../interfaces/Oracle_Interface.sol';

contract B0xOrderTaking is B0xStorage, Proxiable, InternalFunctions {
    using SafeMath for uint256;

    function B0xOrderTaking() public {}
    
    function initialize(
        address _target)
        public
        onlyOwner
    {
        targets[bytes4(keccak256("takeLoanOrderAsTrader(address[6],uint256[9],address,uint256,bytes)"))] = _target;
        targets[bytes4(keccak256("takeLoanOrderAsLender(address[6],uint256[9],bytes)"))] = _target;
        targets[bytes4(keccak256("cancelLoanOrder(address[6],uint256[9],uint256)"))] = _target;
        targets[bytes4(keccak256("cancelLoanOrder(bytes32,uint256)"))] = _target;
        targets[bytes4(keccak256("getLoanOrderHash(address[6],uint256[9])"))] = _target;
        targets[bytes4(keccak256("isValidSignature(address,bytes32,bytes)"))] = _target;
        targets[bytes4(keccak256("getInitialMarginRequired(address,address,address,uint256,uint256)"))] = _target;
        targets[bytes4(keccak256("getUnavailableLoanTokenAmount(bytes32)"))] = _target;
        targets[bytes4(keccak256("getOrders(address,uint256,uint256)"))] = _target;
        targets[bytes4(keccak256("getLoanPositions(address,uint256,uint256)"))] = _target;
        targets[bytes4(keccak256("getLoanOrderParts(bytes32)"))] = _target;
        targets[bytes4(keccak256("getLoanPositionParts(bytes32,address)"))] = _target;
    }
    
    /// @dev Takes the order as trader
    /// @param orderAddresses Array of order's makerAddress, loanTokenAddress, interestTokenAddress collateralTokenAddress, feeRecipientAddress, oracleAddress.
    /// @param orderValues Array of order's loanTokenAmount, interestAmount, initialMarginAmount, maintenanceMarginAmount, lenderRelayFee, traderRelayFee, expirationUnixTimestampSec, makerRole (0=lender, 1=trader), and salt.
    /// @param collateralTokenFilled Desired address of the collateralTokenAddress the trader wants to use.
    /// @param loanTokenAmountFilled Desired amount of loanToken the trader wants to borrow.
    /// @param signature ECDSA signature in raw bytes (rsv).
    /// @return Total amount of loanToken borrowed (uint).
    /// @dev Traders can take a portion of the total coin being lended (loanTokenAmountFilled).
    /// @dev Traders also specify the token that will fill the margin requirement if they are taking the order.
    function takeLoanOrderAsTrader(
        address[6] orderAddresses,
        uint[9] orderValues,
        address collateralTokenFilled,
        uint loanTokenAmountFilled,
        bytes signature)
        external
        nonReentrant
        tracksGas
        returns (uint)
    {
        return _takeLoanOrder(
            orderAddresses,
            orderValues,
            collateralTokenFilled,
            loanTokenAmountFilled,
            signature,
            1 // takerRole
        );
    }

    /// @dev Takes the order as lender
    /// @param orderAddresses Array of order's makerAddress, loanTokenAddress, interestTokenAddress collateralTokenAddress, feeRecipientAddress, oracleAddress.
    /// @param orderValues Array of order's loanTokenAmount, interestAmount, initialMarginAmount, maintenanceMarginAmount, lenderRelayFee, traderRelayFee, expirationUnixTimestampSec, makerRole (0=lender, 1=trader), and salt.
    /// @param signature ECDSA signature in raw bytes (rsv).
    /// @return Total amount of loanToken borrowed (uint).
    /// @dev Lenders have to fill the entire desired amount the trader wants to borrow.
    /// @dev This makes loanTokenAmountFilled = loanOrder.loanTokenAmount.
    function takeLoanOrderAsLender(
        address[6] orderAddresses,
        uint[9] orderValues,
        bytes signature)
        external
        nonReentrant
        tracksGas
        returns (uint)
    {
        return _takeLoanOrder(
            orderAddresses,
            orderValues,
            orderAddresses[3], // collateralTokenFilled
            orderValues[0], // loanTokenAmountFilled
            signature,
            0 // takerRole
        );
    }

    function cancelLoanOrder(
        address[6] orderAddresses,
        uint[9] orderValues,
        uint cancelLoanTokenAmount)
        external
        nonReentrant
        tracksGas
        returns (uint)
    {
        LoanOrder memory loanOrder = buildLoanOrderStruct(
            getLoanOrderHash(orderAddresses, orderValues),
            orderAddresses,
            orderValues
        );

        require(loanOrder.maker == msg.sender);

        return _cancelLoanOrder(loanOrder, cancelLoanTokenAmount);
    }

    function cancelLoanOrder(
        bytes32 loanOrderHash,
        uint cancelLoanTokenAmount)
        external
        nonReentrant
        tracksGas
        returns (uint)
    {
        LoanOrder memory loanOrder = orders[loanOrderHash];
        if (loanOrder.maker == address(0)) {
            return intOrRevert(0,124);
        }

        require(loanOrder.maker == msg.sender);

        return _cancelLoanOrder(loanOrder, cancelLoanTokenAmount);
    }

    /// @dev Calculates Keccak-256 hash of order with specified parameters.
    /// @param orderAddresses Array of order's maker, loanTokenAddress, interestTokenAddress collateralTokenAddress, and feeRecipientAddress.
    /// @param orderValues Array of order's loanTokenAmount, interestAmount, initialMarginAmount, maintenanceMarginAmount, lenderRelayFee, traderRelayFee, expirationUnixTimestampSec, makerRole (0=lender, 1=trader), and salt.
    /// @return Keccak-256 hash of loanOrder.
    function getLoanOrderHash(
        address[6] orderAddresses, 
        uint[9] orderValues)
        public
        view
        returns (bytes32)
    {
        return(keccak256(
            address(this),
            orderAddresses,
            orderValues
        ));
    }

    /// @dev Verifies that an order signature is valid.
    /// @param signer address of signer.
    /// @param hash Signed Keccak-256 hash.
    /// @param signature ECDSA signature in raw bytes (rsv).
    /// @return Validity of order signature.
    function isValidSignature(
        address signer,
        bytes32 hash,
        bytes signature)
        public
        pure
        returns (bool)
    {
        return _isValidSignature(
            signer,
            hash,
            signature);
    }

    function getInitialMarginRequired(
        address positionTokenAddress,
        address collateralTokenAddress,
        address oracleAddress,
        uint positionTokenAmount,
        uint initialMarginAmount)
        public
        view
        returns (uint collateralTokenAmount)
    {
        return _getInitialMarginRequired(
            positionTokenAddress,
            collateralTokenAddress,
            oracleAddress,
            positionTokenAmount,
            initialMarginAmount);
    }

    /// @dev Calculates the sum of values already filled and cancelled for a given loanOrder.
    /// @param loanOrderHash The Keccak-256 hash of the given loanOrder.
    /// @return Sum of values already filled and cancelled.
    function getUnavailableLoanTokenAmount(bytes32 loanOrderHash)
        public
        view
        returns (uint)
    {
        return orderFilledAmounts[loanOrderHash].add(orderCancelledAmounts[loanOrderHash]);
    }

    function getOrders(
        address loanParty,
        uint start,
        uint count)
        public
        view
        returns (bytes)
    {
        uint end = Math.min256(loanList[loanParty].length, start.add(count));
        if (end == 0 || start >= end) {
            return;
        }

        // size of bytes = ((addrs.length(6) + uints.length(7) + 1) * 32) * (end-start)
        bytes memory data = new bytes(448 * (end - start)); 

        for (uint j=0; j < end-start; j++) {
            bytes32 loanOrderHash = loanList[loanParty][j+start].loanOrderHash;
            address[6] memory addrs;
            uint[7] memory uints;
            (addrs, uints) = getLoanOrderParts(loanOrderHash);

            uint i;

            // handles address
            for(i = 1; i <= addrs.length; i++) {
                address tmpAddr = addrs[i-1];
                assembly {
                    mstore(add(data, mul(add(i, mul(j, 14)), 32)), tmpAddr) // mul(j, 14) since 14 items per loanOrder object
                }
            }

            // handles uint
            for(i = addrs.length+1; i <= addrs.length+uints.length; i++) {
                uint tmpUint = uints[i-1-addrs.length];
                assembly {
                    mstore(add(data, mul(add(i, mul(j, 14)), 32)), tmpUint) // mul(j, 14) since 14 items per loanOrder object
                }
            }

            // handles bytes32
            i = addrs.length + uints.length + 1;
            assembly {
                mstore(add(data, mul(add(i, mul(j, 14)), 32)), loanOrderHash) // mul(j, 14) since 14 items per loanOrder object
            }
        }

        return data;
    }

    function getLoanPositions(
        address loanParty,
        uint start,
        uint count)
        public
        view
        returns (bytes)
    {
        uint end = Math.min256(loanList[loanParty].length, start.add(count));
        if (end == 0 || start >= end) {
            return;
        }

        // size of bytes = ((addrs.length(4) + uints.length(5)) * 32) * (end-start)
        bytes memory data = new bytes(288 * (end - start)); 

        for (uint j=0; j < end-start; j++) {
            bytes32 loanOrderHash = loanList[loanParty][j+start].loanOrderHash;
            if (loanPositions[loanOrderHash][loanParty].loanTokenAmountFilled == 0) {
                // loanParty is lender, so it needs to be set to the trader counterparty to retrieve the loan details
                loanParty = loanList[loanParty][j+start].counterparty; // loanParty is now the trader
            }
            address[4] memory addrs;
            uint[5] memory uints;
            (addrs, uints) = getLoanPositionParts(loanOrderHash, loanParty);

            uint i;

            // handles address
            for(i = 1; i <= addrs.length; i++) {
                address tmpAddr = addrs[i-1];
                assembly {
                    mstore(add(data, mul(add(i, mul(j, 9)), 32)), tmpAddr) // mul(j, 14) since 14 items per loanPosition object
                }
            }

            // handles uint
            for(i = addrs.length+1; i <= addrs.length+uints.length; i++) {
                uint tmpUint = uints[i-1-addrs.length];
                assembly {
                    mstore(add(data, mul(add(i, mul(j, 9)), 32)), tmpUint) // mul(j, 14) since 14 items per loanPosition object
                }
            }
        }

        return data;
    }

    function getLoanOrderParts (
        bytes32 loanOrderHash)
        public
        view
        returns (address[6],uint[7])
    {
        LoanOrder memory loanOrder = orders[loanOrderHash];
        if (loanOrder.maker == address(0)) {
            return;
        }

        return (
            [
                loanOrder.maker,
                loanOrder.loanTokenAddress,
                loanOrder.interestTokenAddress,
                loanOrder.collateralTokenAddress,
                loanOrder.feeRecipientAddress,
                loanOrder.oracleAddress
            ],
            [
                loanOrder.loanTokenAmount,
                loanOrder.interestAmount,
                loanOrder.initialMarginAmount,
                loanOrder.maintenanceMarginAmount,
                loanOrder.lenderRelayFee,
                loanOrder.traderRelayFee,
                loanOrder.expirationUnixTimestampSec
            ]
        );
    }

    function getLoanPositionParts (
        bytes32 loanOrderHash,
        address trader)
        public
        view
        returns (address[4], uint[5])
    {
        LoanPosition memory loanPosition = loanPositions[loanOrderHash][trader];
        if (loanPosition.loanTokenAmountFilled == 0 || !loanPosition.active) {
            return;
        }

        return (
            [
                loanPosition.lender,
                loanPosition.trader,
                loanPosition.collateralTokenAddressFilled,
                loanPosition.positionTokenAddressFilled
            ],
            [
                loanPosition.loanTokenAmountFilled,
                loanPosition.collateralTokenAmountFilled,
                loanPosition.positionTokenAmountFilled,
                loanPosition.loanStartUnixTimestampSec,
                loanPosition.active ? 1 : 0
            ]
        );
    }


    function _takeLoanOrder(
        address[6] orderAddresses,
        uint[9] orderValues,
        address collateralTokenFilled,
        uint loanTokenAmountFilled,
        bytes signature,
        uint takerRole) // (0=lender, 1=trader)
        internal
        returns (uint)
    {
        address lender;
        address trader;
        if (takerRole == 1) { // trader
            lender = orderAddresses[0]; // maker
            trader = msg.sender;
        } else { // lender
            lender = msg.sender;
            trader = orderAddresses[0]; // maker
        }
        
        bytes32 loanOrderHash = getLoanOrderHash(orderAddresses, orderValues);
        LoanOrder memory loanOrder = orders[loanOrderHash];
        if (loanOrder.maker == address(0)) {
            // no previous partial loan fill
            loanOrder = buildLoanOrderStruct(loanOrderHash, orderAddresses, orderValues);
            orders[loanOrder.loanOrderHash] = loanOrder;
            loanList[lender].push(Counterparty({
                counterparty: trader,
                loanOrderHash: loanOrder.loanOrderHash
            }));
            loanList[trader].push(Counterparty({
                counterparty: lender,
                loanOrderHash: loanOrder.loanOrderHash
            }));
        } else {
            // previous partial/complete loan fill by another trader
            loanList[trader].push(Counterparty({
                counterparty: lender,
                loanOrderHash: loanOrder.loanOrderHash
            }));
        }

        if (!_isValidSignature(
            loanOrder.maker,
            loanOrder.loanOrderHash,
            signature
        )) {
            return intOrRevert(0,405);
        }

        // makerRole (orderValues[7]) and takerRole must not be equal and must have a value <= 1
        if (orderValues[7] > 1 || takerRole > 1 || orderValues[7] == takerRole) {
            return intOrRevert(0,410);
        }

        // A trader can only fill a portion or all of a loanOrder once:
        //  - this avoids complex interest payments for parts of an order filled at different times by the same trader
        //  - this avoids potentially large loops when calculating margin reqirements and interest payments
        LoanPosition storage loanPosition = loanPositions[loanOrder.loanOrderHash][trader];
        if (loanPosition.loanTokenAmountFilled != 0) {
            return intOrRevert(0,418);
        }     

        uint collateralTokenAmountFilled = _fillLoanOrder(
            loanOrder,
            trader,
            lender,
            collateralTokenFilled,
            loanTokenAmountFilled
        );

        orderFilledAmounts[loanOrder.loanOrderHash] = orderFilledAmounts[loanOrder.loanOrderHash].add(loanTokenAmountFilled);

        loanPosition.lender = lender;
        loanPosition.trader = trader;
        loanPosition.collateralTokenAddressFilled = collateralTokenFilled;
        loanPosition.positionTokenAddressFilled = loanOrder.loanTokenAddress;
        loanPosition.loanTokenAmountFilled = loanTokenAmountFilled;
        loanPosition.collateralTokenAmountFilled = collateralTokenAmountFilled;
        loanPosition.positionTokenAmountFilled = loanTokenAmountFilled;
        loanPosition.loanStartUnixTimestampSec = block.timestamp;
        loanPosition.active = true;

        emit LoanPositionUpdated (
            loanPosition.lender,
            loanPosition.trader,
            loanPosition.collateralTokenAddressFilled,
            loanPosition.positionTokenAddressFilled,
            loanPosition.loanTokenAmountFilled,
            loanPosition.collateralTokenAmountFilled,
            loanPosition.positionTokenAmountFilled,
            loanPosition.loanStartUnixTimestampSec,
            loanPosition.active,
            loanOrder.loanOrderHash
        );

        if (collateralTokenAmountFilled > 0) {
            if (! Oracle_Interface(loanOrder.oracleAddress).didTakeOrder(
                loanOrder.loanOrderHash,
                msg.sender,
                gasUsed // initial used gas, collected in modifier
            )) {
                return intOrRevert(0,460);
            }
        }

        return loanTokenAmountFilled;
    }

    function _fillLoanOrder(
        LoanOrder loanOrder,
        address trader,
        address lender,
        address collateralTokenFilled,
        uint loanTokenAmountFilled)
        internal
        returns (uint)
    {
        if (!_verifyLoanOrder(loanOrder, collateralTokenFilled, loanTokenAmountFilled)) {
            return intOrRevert(0,477);
        }

        uint collateralTokenAmountFilled = _getInitialMarginRequired(
            loanOrder.loanTokenAddress,
            collateralTokenFilled,
            loanOrder.oracleAddress,
            loanTokenAmountFilled,
            loanOrder.initialMarginAmount
        );
        if (collateralTokenAmountFilled == 0) {
            return intOrRevert(0,488);
        }

        if (! B0xVault(VAULT_CONTRACT).depositCollateral(
            collateralTokenFilled,
            trader,
            collateralTokenAmountFilled
        )) {
            return intOrRevert(loanTokenAmountFilled,496);
        }

        // total interest required if loan is kept until order expiration
        // unused interest at the end of a loan is refunded to the trader
        uint totalInterestRequired = _getTotalInterestRequired(
            loanOrder.loanTokenAmount,
            loanTokenAmountFilled,
            loanOrder.interestAmount,
            loanOrder.expirationUnixTimestampSec,
            block.timestamp);
        if (! B0xVault(VAULT_CONTRACT).depositInterest(
            loanOrder.interestTokenAddress,
            trader,
            totalInterestRequired
        )) {
            return intOrRevert(loanTokenAmountFilled,512);
        }

        if (! B0xVault(VAULT_CONTRACT).depositFunding(
            loanOrder.loanTokenAddress,
            lender,
            loanTokenAmountFilled
        )) {
            return intOrRevert(loanTokenAmountFilled,520);
        }

        if (loanOrder.feeRecipientAddress != address(0)) {
            if (loanOrder.traderRelayFee > 0) {
                uint paidTraderFee = _getPartialAmountNoError(loanTokenAmountFilled, loanOrder.loanTokenAmount, loanOrder.traderRelayFee);
                
                if (! B0xVault(VAULT_CONTRACT).transferTokenFrom(
                    B0X_TOKEN_CONTRACT, 
                    trader,
                    loanOrder.feeRecipientAddress,
                    paidTraderFee
                )) {
                    return intOrRevert(loanTokenAmountFilled,533);
                }
            }
            if (loanOrder.lenderRelayFee > 0) {
                uint paidLenderFee = _getPartialAmountNoError(loanTokenAmountFilled, loanOrder.loanTokenAmount, loanOrder.lenderRelayFee);
                
                if (! B0xVault(VAULT_CONTRACT).transferTokenFrom(
                    B0X_TOKEN_CONTRACT, 
                    lender,
                    loanOrder.feeRecipientAddress,
                    paidLenderFee
                )) {
                    return intOrRevert(0,545);
                }
            }
        }

        return collateralTokenAmountFilled;
    }

    function _verifyLoanOrder(
        LoanOrder loanOrder,
        address collateralTokenFilled,
        uint loanTokenAmountFilled)
        internal
        returns (bool)
    {
        if (loanOrder.maker == msg.sender) {
            return boolOrRevert(false,561);
        }
        if (loanOrder.loanTokenAddress == address(0) 
            || loanOrder.interestTokenAddress == address(0)
            || collateralTokenFilled == address(0)) {
            return boolOrRevert(false,566);
        }

        if (loanTokenAmountFilled > loanOrder.loanTokenAmount) {
            return boolOrRevert(false,570);
        }

        if (! OracleRegistry(ORACLE_REGISTRY_CONTRACT).hasOracle(loanOrder.oracleAddress)) {
            return boolOrRevert(false,574);
        }

        if (block.timestamp >= loanOrder.expirationUnixTimestampSec) {
            //LogError(uint8(Errors.ORDER_EXPIRED), 0, loanOrder.loanOrderHash);
            return boolOrRevert(false,579);
        }

        if (loanOrder.maintenanceMarginAmount == 0 || loanOrder.maintenanceMarginAmount >= loanOrder.initialMarginAmount) {
            return boolOrRevert(false,583);
        }

        uint remainingLoanTokenAmount = loanOrder.loanTokenAmount.sub(getUnavailableLoanTokenAmount(loanOrder.loanOrderHash));
        if (remainingLoanTokenAmount < loanTokenAmountFilled) {
            return boolOrRevert(false,588);
        }

        return true;
    }

    // this cancels any reminaing un-loaned loanToken in the order
    function _cancelLoanOrder(
        LoanOrder loanOrder,
        uint cancelLoanTokenAmount)
        internal
        returns (uint)
    {
        require(loanOrder.loanTokenAmount > 0 && cancelLoanTokenAmount > 0);

        if (block.timestamp >= loanOrder.expirationUnixTimestampSec) {
            return 0;
        }

        uint remainingLoanTokenAmount = loanOrder.loanTokenAmount.sub(getUnavailableLoanTokenAmount(loanOrder.loanOrderHash));
        uint cancelledLoanTokenAmount = Math.min256(cancelLoanTokenAmount, remainingLoanTokenAmount);
        if (cancelledLoanTokenAmount == 0) {
            // none left to cancel
            return 0;
        }

        orderCancelledAmounts[loanOrder.loanOrderHash] = orderCancelledAmounts[loanOrder.loanOrderHash].add(cancelledLoanTokenAmount);

        // TODO: needs event
    
        return cancelledLoanTokenAmount;
    }
}
