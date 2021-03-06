# -*- mode: ruby -*-

# The second protocol goes through a multistep process of finding from
# the pool of silos its creation service, then POSTing the data to a
# URL constructed for it.  It doesn't need to know low-level internals
# of the pool, such as the internal disk partition information
#

Feature: Manage the life cycle of a package on a silo partition, protocol 2

  In order to POST packages to a pool
  As a storage web service client of a disk-master-based silo
  I want to POST, GET, and DELETE a package

  Scenario: store a package to a silo, retrieve it and delete it
    Given a pool
    And a new package

    When I GET the service document from the pool
    Then I should see "200 OK"
    And I should receive a create URL in the response

    When I POST the package to the create URL
    Then I should see "201 Created"
    And I should get the location of the stored package

    When I GET the stored package for the first time
    Then I should see "200 OK"
    And the checksum of the retrieved package should match the original package

    When I POST the package to the create URL a second time
    Then I should see "403 Forbidden"

    When I GET the stored package for the second time
    Then I should see "200 OK"
    And the checksum of the retrieved package should match the original package

    When I DELETE the stored package for the first time
    Then I should see "204 No Content"

    When I GET the stored package after deletion
    Then I should see "404 Not Found"

    When I DELETE the stored package for a second time
    Then I should see "404 Not Found"

# TODO: when silos can support 410 we'll need to support this feature as well
#
#    When I POST the package to the create URL after it was DELETEd
#    Then I should see "403 Forbidden"

