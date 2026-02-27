APP_NAME := partition_growth
SRC := main.go
OUTPUT_DIR := build

PLATFORMS := \
    darwin/amd64 \
    darwin/arm64 \
    linux/amd64 \
    linux/arm64

all: $(PLATFORMS)
	@echo "✅ Cross-compilation complete."

$(PLATFORMS):
	@GOOS=$(word 1,$(subst /, ,$@)) \
	GOARCH=$(word 2,$(subst /, ,$@)) \
	go build -o $(OUTPUT_DIR)/$(APP_NAME)-$(word 1,$(subst /, ,$@))-$(word 2,$(subst /, ,$@)) $(SRC)

clean:
	@rm -rf $(OUTPUT_DIR)

