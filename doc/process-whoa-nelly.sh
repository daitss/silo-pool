#!/bin/bash

background='#ffeeee'


scale=0.15

if [ -z $1 ] ; then
   echo Usage: $0 source-png ...
   exit 1
fi

if [ ! -f $source ] ; then
   echo "Source image $source doesnt exist"
   exit 1
fi


# when we're trying to blend in

for i in "$@"; do
  source="$i"
  destination=../public/"`basename $source`"
  echo $destination
  pngtopnm $source | pnmscale $scale | pnmcrop | pnmmargin -color "$background" 2 | pnmtopng -transparent "$background" > $destination
done
