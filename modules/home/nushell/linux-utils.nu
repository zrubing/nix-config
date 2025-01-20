# List USB devices
export def "sys usb" [] {
  ^lsusb
  | parse "Bus {bus} Device {device}: ID {vendor}:{product} {name}"
  | upsert name { str trim } 
  | into value -c [bus device]
}
