#!/usr/bin/env bash

echo "---------------------------------------"
echo "   deploying development environment   "
echo "---------------------------------------"

#Build docker container
docker build -t sketch2map-development .

#Run docker container
docker run -v $(pwd):/home/sketch2map -it -p 80:80 -p 8000:8000 painteraction-development bash
