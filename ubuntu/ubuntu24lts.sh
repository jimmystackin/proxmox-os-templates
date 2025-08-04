#!/bin/bash

#Change if Ubuntu moves FQDN
UBUNTU_CLOUDIMAGE_FQDN="https://cloud-images.ubuntu.com"

# Make sure JQ is installed
if ! command -v jq &> /dev/null; then
  echo -n "need jq to proceed.  Install? (y/n): "
  read -r answer
  case "$answer" in
    [Yy]* )
      echo "installing jq..."
      apt-get update && apt-get install -y jq
      ;;
    * )
      echo "exiting"
      exit 1
      ;;
  esac
fi

# Get Filename
self_full_name=$(basename -- "${BASH_SOURCE[0]}")
self_name="${self_full_name%.*}"

# Determine which JSON to use for VARs
if [ -f ".$self_name.json" ]; then
  vars_file=".$self_name.json"
else
  vars_file="$self_name.json"
fi

# Get Vars
eval $(jq -r '.execution_parameters | to_entries | .[] | "export \(.key)=\(.value)"' "$vars_file")
eval $(jq -r '.version_parameters | to_entries | .[] | "export \(.key)=\(.value|@sh)"' "$vars_file")
eval $(jq -r '.template_parameters | to_entries | .[] | "export \(.key)=\(.value|@sh)"' "$vars_file")


if command -v guestfish &> /dev/null; then
  if [ "$install_apt_prereqs" == "1" ]; then
    apt-get install -y libguestfs-tools
  fi
else
  echo "please install libguestfs-tools or set install_apt_prereqs to 1"
  exit 1
fi

if [ "$force_create_new" == "1" ];
  CREATE_NEW=1
else
  CREATE_NEW=0
fi

download_directory="$working_directory/downloads"
image_file_name="$ubuntu_release_name-server-cloudimg-$ubuntu_archtype.img"
image_download_src=$UBUNTU_CLOUDIMAGE_FQDN/$ubuntu_release_name/$ubuntu_build/$image_file_name
md5_download_src=$UBUNTU_CLOUDIMAGE_FQDN/$ubuntu_release_name/$ubuntu_build/$md5_filename
image_local_path=$download_directory/$image_file_name

template_name="ubu$ubuntu_release_number_$(date +"%Y-%m-%d-%H-%M-%S")"

# Make sure working & download dirs all exists
if [ ! -d "$download_directory" ]; then
  mkdir -p $download_directory
fi

# If file exists check hash, if invalid delete
if [ -f "$image_local_path" ]; then
  local_md5=$(md5sum "$image_local_path" | awk '{print $1}')
  online_md5=$(curl -s "$image_local_path" | grep "$image_file_name" | awk '{print $1}')

  if [ "$online_md5" != "$local_md5" ]; then
    rm -rf $image_local_path
    CREATE_NEW=1
  fi
else
  CREATE_NEW=1
fi

# check if VM template exists
if [ "$CREATE_NEW" == "1" ]; then

  while true; do

    if qm status "$vm_id" &>/dev/null; then
      break
    fi

    basediskname="vm-$vmid-disk-0"
    disk_in_use=0

    while read -r other_vm_id; do
      [[ "$other_vm_id" == "$vm_id" ]] && continue
      if qm config "$other_vm_id" | grep -q "basediskname"; then
        disk_in_use=1
        break
      fi
    done < <(qm list | awk 'NR>1 {print $1}')

    if [ "disk_in_use" == "0" ]; then
      qm destroy "$vm_id" --purge
      break
    else
      (($vm_id++))
    fi
  done

  cp $image_local_path /tmp/$image_file_name

  if [ "$expand_image_by_20" == "1" ]; then
    qemu-img resize /tmp/$image_file_name +20G
  fi

  if [ "$install_guest_agent" == "1" ]; then
    virt-customize --install qemu-guest-agent -a /tmp/$image_file_name
  fi

  qm create "$vm_id" --name "$template_name" --cpu "$vm_cpu_type" --cores "$vm_cpu_ct" --memory "$vm_mem_mb" --net0 virtio,bridge="$vm_net_bridge"
  qm importdisk "$vm_id" /tmp/$image_file_name "$vm_def_storage"
  qm set "$vm_id" --scsihw virtio-scsi-pci --scsi0 "$vm_def_storage":"$vm_id"/vm-"$basediskname".raw
  qm set "$vm_id" --ide2 "$vm_id":cloudinit
  qm set "$vm_id" --boot c --bootdisk scsi0
  qm set "$vm_id" --serial0 socket --vga serial0
  qm set "$vm_id" --ipconfig0 ip=dhcp

  if [ "$set_ci_username" == "1" ]; then
    qm set "$vm_id" --ciuser "$vm_username"
  fi

  if [ "$match_ci_pw_to_root" == "1" ]; then
    qm set "$vm_id" --cipassword "$(getent shadow root | cut -d: -f2)"
  fi

  qm template "$vm_id"

  rm -rf /tmp/$image_file_name
fi
