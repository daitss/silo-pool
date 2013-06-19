Core Service
==========================

Current Production code
-----------------------
git commit sha1 - 2adb991da7a7465d07657e721f94e98c01c84234




A silo pool is a RESTful web service that allows packages to be stored to one of a collection of disk partitions. This page serves to document the two protocols for storing package data.

Simple PUT

Initially, a simple PUT based protocol was developed; a client had to know the exact location that a package could be stored to. Two subsequent PUTs to the same location was not allowed. Subsequent to a successful PUT, the URL could be used to retrieve the package via a GET, package metadata via a HEAD, or to delete the package via an HTTP DELETE.

Three HTTP headers are required:

    Content-MD5
    Content-Type
    Content-Length

The Content-MD5 is used to check the integrity of the file transfer. The only content type currently supported is that of application/x-tar. The request/response interaction is diagrammed below:

The XML document that is returned on a successful PUT is as follows:

       <?xml version="1.0" encoding="UTF-8"?>
       <created 
	      ieid="E20100727_AAAAAB"   
	  location="http://silo-pool.example.org/data/02/E20100727_AAAAAB.000" 
	       md5="15e4aeae105dc0cfc8edb2dd4c79454e" 
	      name="E20100727_AAAAAB.000" 
	      sha1="a5ffd229992586461450851d434e3ce51debb626" 
	      size="8172435" 
	      type="application/x-tar"
       />

The computed SHA1 is returned so that the client can do further integrity checks, if desired.

Note that the disk partitions /daitssfs/01, /daitssfs/02, etc, are mapped directly to URLs. For example, /daitssfs/02 is exposed as the URL http://silo-pool.example.org/data/02/. The client (e.g. DAITSS, Storage Master, Fixity Checks) must be made aware of the available partitions on the silo pool servers it uses.
Create via POST

As DAITSS scaled up, informing clients about newly added partitions turned out to be awkward. In particular, it was difficult to stage new partitions so that a partition was completely filled by package data. To simplify management, a modified protocol that POSTs the data to a URL not specific to a particular disk partition was developed. A modified protocol was developed so that clients did not have to have knowledge of the internals of the silo pools:

The XML document is exactly the same as provided by the earlier protocol, but the silo pool service determines which partition is selected. As before, existing packages cannot be over-written.
The service document

In an attempt to future-proof the behavior of silo pools, a service document URL was created to allow clients to inquire about the services provided. http://silo-pool.example.org/services returns an XML document along the following lines:


     <?xml version="1.0" encoding="UTF-8"?>
     <services version="1.1.5">
       <create location="http://silo-pool.dev/create/%s" method="post"/>
       <fixity location="http://silo-pool.dev/fixity.csv" mime_type="text/csv" method="get"/>
       <fixity location="http://silo-pool.dev/fixity.xml" mime_type="application/xml" method="get"/>
       <partition_fixity mime_type="application/xml" method="get" location="http://silo-pool.dev/01/fixity/"/>
       <partition_fixity mime_type="application/xml" method="get" location="http://silo-pool.dev/02/fixity/"/>
       <partition_fixity mime_type="application/xml" method="get" location="http://silo-pool.dev/03/fixity/"/>
       <store location="http://silo-pool.dev/01/data/%s" method="put"/>
       <store location="http://silo-pool.dev/02/data/%s" method="put"/>
       <store location="http://silo-pool.dev/03/data/%s" method="put"/>
       <retrieve location="http://silo-pool.dev/01/data/%s" method="get"/>
       <retrieve location="http://silo-pool.dev/02/data/%s" method="get"/>
       <retrieve location="http://silo-pool.dev/03/data/%s" method="get"/>
     </services>  

Note the create element: this provides a template for a client to create a new package. Clients may first retrieve this document to determine the creation URL and its method. The Storage Master service uses this technique.
A brief note on using the protocols

While it might seem that the first protocol has been superseded, it has proven convenient in handling certain error conditions. For instance, if a fixity error is detected because of disk corruption, the offending package can be DELETEd and replaced by a correct copy.
