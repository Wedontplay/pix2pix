#Dockerfile

FROM kaixhin/cuda-torch
MAINTAINER "gambotto@leva.io"

#install needed software
RUN apt-get update && apt-get install -y wget

#install invidia key
RUN wget -qO - http://developer.download.nvidia.com/compute/cuda/repos/ubuntu1404/x86_64/7fa2af80.pub | sudo apt-key add -

#install dependencies
RUN luarocks install nngraph 
RUN luarocks install https://raw.githubusercontent.com/szym/display/master/display-scm-0.rockspec

# Prepare folders
RUN mkdir /home/sketch2map

# Add the app
ADD . /home/sketch2map

#set working directory
WORKDIR /home/sketch2map

RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

