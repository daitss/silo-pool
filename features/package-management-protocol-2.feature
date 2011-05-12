# -*- mode: ruby -*-

# The second protocol goes through a multistep process of finding from
# the pool of silos its creation service, then POSTing the data to a
# URL constructed for it.  It doesn't need to know low-level internals
# of the pool, such as the internal disk partition information

Feature: Manage the life cycle of a package on a silo partition, protocol 2

  In order to POST packages to a pool
  As a storage web service client of a disk_master-based silo
  I want to PUT, GET, and DELETE a package

  Scenario: store a package to a silo
    Given a pool
    And a new package
    When I GET the service document from the pool
    Then I should see "200 OK"
    And I should receive a create URL in the response
    When I POST the package to the create URL
    Then I should see "201 Created"
    And I should get the location of the stored package
    When I DELETE the stored package
    Then I should see "204 No Content"


#### Add get before delete
#### Add get after delete
#### Add delete after delete

#### Add additional attempts to post same document
