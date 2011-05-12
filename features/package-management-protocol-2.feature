# -*- mode: ruby -*-

# The second protocol goes through a multistep process of finding the creation service,
# then POSTing the data to a URL constructed for it.  It doesn't need to know low-level
# internals of the silo.

Feature: Manage the life cycle of a package on a silo partition

  In order to POST packages to a pool
  As a storage web service client of a disk_master-based silo
  I want to PUT, GET, and DELETE a package


  Scenario: store a package to a silo
    Given a pool
    And a new package
    When I GET the service document
    Then I should see "200 OK"
    And I should receive a create URL in the response
