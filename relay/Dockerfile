FROM golang:1.25-bookworm AS base

WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .

FROM base AS test
RUN go test ./...

FROM base AS build
ARG TARGETOS=linux
ARG TARGETARCH=arm64
RUN mkdir -p /out && \
    CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" go build -trimpath -ldflags="-s -w" -o /out/ridenow-token ./cmd/ridenow-token && \
    CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" go build -trimpath -ldflags="-s -w" -o /out/ridenow-accessd ./cmd/ridenow-accessd && \
    CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" go build -trimpath -ldflags="-s -w" -o /out/ridenow-relay ./cmd/ridenow-relay

FROM scratch AS export
COPY --from=build /out/ /

