#!/bin/bash

# Variables
IMAGE_NAME="img-multitec-web"
CONTAINER_NAME="con-multitec-web"
DOCKERFILE_PATH="."

# Build the Docker image
echo "Building the Docker image..."
docker build -t $IMAGE_NAME $DOCKERFILE_PATH

# Check if a container with the same name is already running and stop it
if [ "$(docker ps -q -f name=$CONTAINER_NAME)" ]; then
    echo "Stopping and removing existing container..."
    docker stop $CONTAINER_NAME
    docker rm $CONTAINER_NAME
fi

# Run the Docker container
echo "Running the Docker container..."
docker run -d --name $CONTAINER_NAME -p 80:80 $IMAGE_NAME
docker logs $CONTAINER_NAME -f

echo "Docker container is running at http://localhost:80"

