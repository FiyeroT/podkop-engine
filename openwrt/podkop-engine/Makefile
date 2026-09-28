# podkop-engine: sing-box с патчами для podkop (REALITY под Xray-core 26.9+,
# отпечатки firefox/safari как у Xray, сборка без api/snell).
# Основан на net/sing-box из openwrt/packages (GPL-2.0). version.mk и patches/
# кладёт сюда scripts/sdk-build.sh для выбранной ветки sing-box.

# Отличия от net/sing-box: нет +kmod-tun (TUN podkop не использует, у него tproxy,
# а kmod-nft-tproxy тянет сам podkop) и +kmod-inet-diag (нужен только find_process).

include $(TOPDIR)/rules.mk
include $(CURDIR)/version.mk

PKG_NAME:=podkop-engine
PKG_VERSION:=$(SB_VERSION)
PKG_RELEASE:=$(SB_RELEASE)

PKG_SOURCE:=sing-box-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/SagerNet/sing-box/tar.gz/v$(PKG_VERSION)?
PKG_HASH:=$(SB_HASH)
PKG_BUILD_DIR:=$(BUILD_DIR)/sing-box-$(PKG_VERSION)

PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=podkop-engine

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/sagernet/sing-box
GO_PKG_BUILD_PKG:=$(GO_PKG)/cmd/sing-box
GO_PKG_TAGS:=with_quic,with_utls,with_clash_api,podkop_slim,badlinkname,tfogo_checklinkname0
GO_PKG_LDFLAGS:=-checklinkname=0
GO_PKG_LDFLAGS_X:=$(GO_PKG)/constant.Version=$(PKG_VERSION)-pdk-r$(PKG_RELEASE)

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/podkop-engine
  TITLE:=sing-box for podkop (REALITY for Xray-core 26.9+, slim)
  SECTION:=net
  CATEGORY:=Network
  URL:=https://github.com/SagerNet/sing-box
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle
  USERID:=sing-box=5566:sing-box=5566
  PROVIDES:=sing-box
  CONFLICTS:=sing-box sing-box-tiny
endef

define Package/podkop-engine/description
  Unofficial build of sing-box for podkop, not affiliated with the sing-box project.
  Patched REALITY client (X25519MLKEM768 key share, Xray-core 26.9+ servers),
  Firefox 148 / Safari 26.3 uTLS fingerprints, no api CLI/service and snell.
  Build tags: $(GO_PKG_TAGS).
endef

define Package/podkop-engine/conffiles
/etc/config/sing-box
/etc/sing-box/
endef

# CLI `sing-box api ...` (gRPC-клиент, ~5 МБ) podkop не нужен: убираем по маске,
# чтобы новые файлы upstream уходили тоже. Регистрацию api/snell снимает тег podkop_slim.
define Build/Prepare
	$(call Build/Prepare/Default)
	$(RM) $(PKG_BUILD_DIR)/cmd/sing-box/cmd_api*.go
endef

define Package/podkop-engine/install
	$(INSTALL_DIR) $(1)/usr/bin/
	$(INSTALL_BIN) $(GO_PKG_BUILD_BIN_DIR)/sing-box $(1)/usr/bin/sing-box

	$(INSTALL_DIR) $(1)/etc/sing-box
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/release/config/config.json $(1)/etc/sing-box

	$(INSTALL_DIR) $(1)/etc/config/
	$(INSTALL_CONF) ./files/sing-box.conf $(1)/etc/config/sing-box
	$(INSTALL_DIR) $(1)/etc/init.d/
	$(INSTALL_BIN) ./files/sing-box.init $(1)/etc/init.d/sing-box
	$(INSTALL_DIR) $(1)/usr/libexec/podkop-engine
	$(INSTALL_BIN) ./files/lists-recovered $(1)/usr/libexec/podkop-engine/lists-recovered
endef

$(eval $(call BuildPackage,podkop-engine))
