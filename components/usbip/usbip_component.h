#pragma once

#include "esphome/core/component.h"
#include <cstdint>
#include <string>
#include <vector>
#include <functional>
#include <utility>

// No forward declarations needed - using BSD sockets

namespace esphome {
namespace usbip {

// USB/IP Protocol version
static constexpr uint16_t USBIP_VERSION = 0x0111;

// USB/IP operation codes
enum USBIPOpCode : uint16_t {
  OP_REQ_DEVLIST = 0x8005,
  OP_REP_DEVLIST = 0x0005,
  OP_REQ_IMPORT = 0x8003,
  OP_REP_IMPORT = 0x0003,
  USBIP_CMD_SUBMIT = 0x0001,
  USBIP_RET_SUBMIT = 0x0003,
  USBIP_CMD_UNLINK = 0x0002,
  USBIP_RET_UNLINK = 0x0004,
};

// USB/IP status codes
enum USBIPStatus : uint32_t {
  ST_OK = 0x00000000,
  ST_NA = 0x00000001,
};

// USB/IP header
struct __attribute__((packed)) USBIPHeader {
  uint16_t version;
  uint16_t command;
  uint32_t status;
};

// USB device path info for DEVLIST
struct __attribute__((packed)) USBIPDeviceInfo {
  char path[256];
  char busid[32];
  uint32_t busnum;
  uint32_t devnum;
  uint32_t speed;
  uint16_t idVendor;
  uint16_t idProduct;
  uint16_t bcdDevice;
  uint8_t bDeviceClass;
  uint8_t bDeviceSubClass;
  uint8_t bDeviceProtocol;
  uint8_t bConfigurationValue;
  uint8_t bNumConfigurations;
  uint8_t bNumInterfaces;
};

// USB interface info
struct __attribute__((packed)) USBIPInterfaceInfo {
  uint8_t bInterfaceClass;
  uint8_t bInterfaceSubClass;
  uint8_t bInterfaceProtocol;
  uint8_t padding;
};

// USBIP_RET_SUBMIT header
struct __attribute__((packed)) USBIPRetSubmit {
  uint32_t command;
  uint32_t seqnum;
  uint32_t devid;
  uint32_t direction;
  uint32_t ep;
  uint32_t status;
  uint32_t actual_length;
  uint32_t start_frame;
  uint32_t number_of_packets;
  uint32_t error_count;
  uint8_t setup[8];
};

// USBIP_RET_UNLINK header
struct __attribute__((packed)) USBIPRetUnlink {
  uint32_t command;
  uint32_t seqnum;
  uint32_t devid;
  uint32_t direction;
  uint32_t ep;
  uint32_t status;
  uint8_t padding[24];
};

// USB device speed (matching Linux USB/IP values)
enum USBIPSpeed : uint32_t {
  USBIP_SPEED_LOW = 1,
  USBIP_SPEED_FULL = 2,
  USBIP_SPEED_HIGH = 3,
};

// Client connection state
enum ClientState {
  CLIENT_STATE_IDLE,
  CLIENT_STATE_DEVLIST,
  CLIENT_STATE_ATTACHED,
};

// HP P1102 firmware upload state
enum FirmwareUploadState {
  FW_STATE_IDLE,                // No firmware action needed
  FW_STATE_MODE_SWITCH_SENT,    // Sent SCSI 0xD0, waiting for disconnect
  FW_STATE_AWAITING_PRINTER,    // Device re-enumerating, expect printer class
  FW_STATE_UPLOADING,           // Sending firmware data
  FW_STATE_AWAITING_READY,      // Firmware sent, waiting for final re-enumeration
  FW_STATE_DONE                 // Firmware loaded, normal operation
};

// Interface descriptor info
struct InterfaceInfo {
  uint8_t interface_number{0};
  uint8_t interface_class{0};
  uint8_t interface_subclass{0};
  uint8_t interface_protocol{0};
};

// Endpoint info
struct EndpointInfo {
  uint8_t address{0};
  uint8_t attributes{0};
  uint16_t max_packet_size{64};
  uint8_t interval{0};
};

// Caps on the interface/endpoint data tracked for an attached device.
// The DEVLIST reply declares bNumInterfaces and then sends exactly that many
// interface records, so the storage cap, the declared count and the number of
// records sent must always agree - otherwise a client that counts records
// while reading desyncs and the attach fails.
static constexpr uint8_t USBIP_MAX_INTERFACES = 10;
static constexpr uint8_t USBIP_MAX_ENDPOINTS = 16;

// Stored USB device information
struct USBDevice {
  bool connected{false};
  bool enumerated{false};
  uint8_t dev_addr{0};
  uint16_t vid{0};
  uint16_t pid{0};
  uint16_t bcd_device{0};
  uint8_t device_class{0};
  uint8_t device_subclass{0};
  uint8_t device_protocol{0};
  uint8_t max_packet_size0{8};
  uint8_t num_configurations{1};
  uint8_t current_configuration{0};
  uint8_t num_interfaces{0};
  USBIPSpeed speed{USBIP_SPEED_FULL};

  // Interface info (up to USBIP_MAX_INTERFACES interfaces)
  InterfaceInfo interfaces[USBIP_MAX_INTERFACES];

  // Endpoint info (up to USBIP_MAX_ENDPOINTS endpoints)
  EndpointInfo endpoints[USBIP_MAX_ENDPOINTS];
  uint8_t num_endpoints{0};

  // Bulk endpoints of the printer interface, used by the RAW print server
  uint8_t printer_bulk_out_ep{0};
  uint8_t printer_bulk_in_ep{0};

  // Device descriptors (cached)
  std::vector<uint8_t> device_descriptor;
  std::vector<uint8_t> config_descriptor;
};

class USBIPComponent : public Component {
 public:
  USBIPComponent();
  ~USBIPComponent();

  void setup() override;
  void loop() override;
  void dump_config() override;
  float get_setup_priority() const override;

  void set_port(uint16_t port) { this->port_ = port; }

  // Enable the JetDirect-style RAW print server (TCP 9100). 0 disables it.
  // Lets a plain TCP client (e.g. a Windows "Standard TCP/IP Port" printer)
  // push a print job straight to the attached USB printer.
  void set_raw_print_port(uint16_t port) { this->raw_port_ = port; }

  // Print a small info card (device name, IP address, ports) on the attached
  // printer once it is enumerated. Lets a user who has no Home Assistant
  // discover the device without ever typing an IP address.
  void set_print_info_card(bool enabled) { this->info_card_enabled_ = enabled; }

  // Advertise the print server via mDNS ("_usbip._tcp"), including the
  // current IP address in the TXT record. Lets a user without Home Assistant
  // find the device from any mDNS browser.
  void set_mdns_discovery(bool enabled) { this->mdns_discovery_ = enabled; }

  // USB Host callbacks
  void on_device_connected(uint8_t dev_addr);
  void on_device_disconnected(uint8_t dev_addr);

 protected:
  // Network handling
  void start_server_();
  void handle_client_();
  void disconnect_client_();

  // Protocol handling
  bool handle_devlist_request_();
  bool handle_import_request_();
  bool handle_urb_();

  // USB/IP message helpers
  void send_devlist_response_();
  void send_import_response_(bool success);
  void send_urb_response_(uint32_t seqnum, int32_t status, const uint8_t *data, uint32_t length);

  // USB host handling
  void usb_host_init_();
  void usb_host_task_();
  bool enumerate_device_(uint8_t dev_addr);
  void init_printer_device_();

  // RAW print server (JetDirect-style, TCP 9100)
  void start_raw_print_server_();
  void handle_raw_client_();
  bool send_printer_bulk_out_(const uint8_t *data, size_t length);
  void find_printer_endpoints_();

  // Info card printing
  void print_info_card_();
  bool build_info_card_(std::string &out);

  // mDNS discovery
  void update_mdns_();
  void build_mdns_txt_(std::vector<std::pair<std::string, std::string>> &records, const std::string &ip);
  bool current_ip_(std::string &ip);
  std::string use_address_();

#ifdef HAS_PRINTER_FIRMWARE
  // HP Smart Install firmware upload
  bool handle_hp_smart_install_();
  bool upload_hp_firmware_();
  bool has_mass_storage_interface_() const;
  bool has_printer_interface_() const;
#endif

  // USB transfer helpers
  bool handle_control_transfer_(uint32_t seqnum, const uint8_t *setup_data, uint32_t data_length,
                                const uint8_t *out_data);
  bool handle_bulk_transfer_(uint32_t seqnum, uint32_t ep, uint32_t direction,
                             const uint8_t *data, uint32_t length);

  // Utility functions
  static uint16_t htons_(uint16_t value);
  static uint32_t htonl_(uint32_t value);
  static uint16_t ntohs_(uint16_t value);
  static uint32_t ntohl_(uint32_t value);

  bool read_bytes_(uint8_t *buffer, size_t length, uint32_t timeout_ms = 1000);
  bool write_bytes_(const uint8_t *buffer, size_t length);

  // Configuration
  uint16_t port_{3240};

  // RAW print server state
  uint16_t raw_port_{0};
  int raw_server_fd_{-1};
  int raw_client_fd_{-1};
  uint32_t raw_bytes_total_{0};

  // Info card state
  bool info_card_enabled_{false};
  bool info_card_pending_{false};
  bool info_card_printed_{false};
  uint32_t info_card_deadline_{0};

  // mDNS discovery state
  bool mdns_discovery_{true};
  bool mdns_registered_{false};
  std::string mdns_ip_;
  uint32_t mdns_retry_at_{0};
  uint32_t mdns_last_check_{0};

  // Server state (using BSD sockets)
  int server_fd_{-1};
  int client_fd_{-1};
  ClientState client_state_{CLIENT_STATE_IDLE};

  // USB device state
  USBDevice usb_device_;
  bool usb_host_initialized_{false};
  void *usb_host_client_hdl_{nullptr};

  // HP P1102 firmware upload state
  FirmwareUploadState fw_state_{FW_STATE_IDLE};

  // Timing
  uint32_t last_usb_check_{0};
};

// Global component reference for callbacks
extern USBIPComponent *g_usbip_component;

}  // namespace usbip
}  // namespace esphome
