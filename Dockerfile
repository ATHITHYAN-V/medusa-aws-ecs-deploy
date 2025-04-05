# Use the official Node.js 18 LTS image as the base
FROM node:18-alpine

# Set the working directory inside the container
WORKDIR /app

# Copy package.json and package-lock.json to the container
COPY package*.json ./

# Install production dependencies
RUN npm ci --only=production

# Copy the rest of the application code to the container
COPY . .

# Expose the port that the Medusa server runs on
EXPOSE 9000

# Command to run the Medusa server
CMD ["npm", "start"]
