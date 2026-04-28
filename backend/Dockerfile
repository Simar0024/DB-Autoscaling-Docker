FROM node:18-alpine
RUN apk add --no-cache curl
WORKDIR /app
COPY package*.json ./

RUN npm install prom-client 

RUN npm install
COPY . .
EXPOSE 3000
CMD ["node", "server.js"]