# Use an official Ubuntu runtime as a parent image
FROM ubuntu:22.04

# Set the working directory in the container to /app
WORKDIR /app

# Install required packages
RUN apt-get update && apt-get install -y \
    docker.io \
    git \
    net-tools \
    curl \
    lsof \
    sudo

# Copy the entire content of the local directory to /app in the container
COPY . /app

# Ensure deploy.sh is executable
RUN chmod +x /app/deploy.sh

# Run deploy.sh when the container launches
CMD ["./deploy.sh"]