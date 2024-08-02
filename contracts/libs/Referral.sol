// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

library Referral {
    /**
     * @dev The struct of linear node information
     * @param referrer The referrer address
     * @param referees The referee address set
     */
    struct LinearNode {
        address referrer;
        address[] referees;
    }

    /**
     * @dev Tree
     * @param linearTree - Table of nodes of the linear tree.
     */
    struct Tree {
        mapping(address => LinearNode) linearTree;
    }

    // Events
    event Registered(address indexed account, address indexed referrer);
    event Removed(address indexed account, address indexed referrer);

    /**
     * @dev Utils function for check whether an address has the referrer
     */
    function hasReferrer(Tree storage self, address account) internal view returns (bool) {
        return self.linearTree[account].referrer != address(0);
    }

    /**
     * @dev Utils function for check whether an address is circular reference
     */
    function isCircularReference(Tree storage self, address referrer, address referee) internal view returns (bool) {
        address parent = referrer;

        while (parent != address(0)) {
            if (parent == referee) {
                return true;
            }
            parent = self.linearTree[parent].referrer;
        }

        return false;
    }

    /**
     * @dev Add an address as referrer
     * @param account The address would set as referee of referrer
     * @param referrer The address would set as referrer of referee
     */
    function register(Tree storage self, address account, address referrer) internal {
        require(account != address(0), "Account cannot be 0x0 address");
        require(referrer != address(0), "Referrer cannot be 0x0 address");
        require(!isCircularReference(self, referrer, account), "Referee cannot be one of referrer upline");
        require(!hasReferrer(self, account), "Address have been registered upline");

        self.linearTree[account].referrer = referrer;
        self.linearTree[referrer].referees.push(account);

        emit Registered(account, referrer);
    }

    function removeReferrer(Tree storage self, address account) internal {
        require(account != address(0), "Account cannot be 0x0 address");
        require(hasReferrer(self, account), "Address have no referrer");

        address referrer = self.linearTree[account].referrer;
        address[] storage referees = self.linearTree[referrer].referees;
        uint length = referees.length;
        for (uint256 i = 0; i < length; ) {
            if (referees[i] == account) {
                referees[i] = referees[length - 1];
                referees.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
        self.linearTree[account].referrer = address(0);

        emit Removed(account, referrer);
    }
}
