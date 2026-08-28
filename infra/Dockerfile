FROM node:22-bookworm-slim

WORKDIR /app

COPY package.json package-lock.json tsconfig.json cdk.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund

COPY bin ./bin
COPY lib ./lib

RUN npm run build

ENTRYPOINT ["npx", "cdk"]
