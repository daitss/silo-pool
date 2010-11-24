# -*- mode: ruby -*-

Feature: Management the life cycle of a package on a silo

  In order to manage packages
  As a storage web service client of a disk_master-based silo
  I want to store, retrieve, and delete a package

  Scenario: store a package to a silo
    Given a silo
    And a new package
    When I retrieve the package
    Then I should see "404 Not Found"
    When I send the package
    Then I should see "201 Created"
    When I retrieve the package
    Then I should see "200 OK"
    And the checksum of the retrieved package should match the package
    When I delete the package 
    Then I should see "204 No Content"
    When I delete the package 
    Then I should see "404 Not Found"

