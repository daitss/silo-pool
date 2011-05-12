# -*- mode: ruby -*-

# We have two methods to handle silos.  The first just PUTs a package
# by name to a particular partition on the silo, if it doesn't already exist.

Feature: Manage the life cycle of a package on a silo partition

  In order to PUT packages to a silo in a pool
  As a storage web service client of a disk_master-based silo
  I want to PUT, GET, and DELETE a package

  Scenario: store a package to a silo
    Given a silo
    And a new package
    When I GET the package
    Then I should see "404 Not Found"
    When I PUT the package
    Then I should see "201 Created"
    When I GET the package
    Then I should see "200 OK"
    And the checksum of the retrieved package should match the package
    When I PUT the package
    Then I should see "403 Forbidden"
    When I DELETE the package 
    Then I should see "204 No Content"
    When I DELETE the package 
    Then I should see "404 Not Found"


# TODO: try a bad name, a bad checksum


