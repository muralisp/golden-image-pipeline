packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "image_name" {
  type    = string
  default = "golden-image"
}

variable "kickstart_file" {
  type    = string
  default = "kickstart/golden.ks"
}

variable "hardening_script" {
  type    = string
  default = "scripts/harden.sh"
}

variable "source_ami" {
  type    = string
  default = "ami-0c94855ba95c71c99" # base RHEL/Rocky AMI, override per account
}

source "amazon-ebs" "golden" {
  ami_name      = "${var.image_name}"
  instance_type = "t3.medium"
  region        = "us-east-1"
  source_ami    = var.source_ami
  ssh_username  = "ec2-user"

  # Kickstart drives the actual unattended OS installation when building
  # from install media / PXE-style boot (e.g. via a custom AMI baking
  # process or on-prem builder plugin). For cloud AMI rebuilds we boot
  # a minimal base image and apply Kickstart-equivalent post-install
  # config via provisioners below, but the same golden.ks file is the
  # single source of truth also used by the PXE workflow for baremetal.
  ami_description = "CIS-hardened golden image built ${timestamp()}"

  tags = {
    Name        = var.image_name
    BuiltBy     = "packer"
    Hardened    = "true"
    KickstartRef = var.kickstart_file
  }
}

build {
  name    = "golden-image"
  sources = ["source.amazon-ebs.golden"]

  # Apply the same package/config baseline defined in golden.ks
  provisioner "shell" {
    inline = [
      "sudo yum update -y",
      "sudo yum install -y vim-enhanced wget curl git aide auditd"
    ]
  }

  # Security hardening: CIS benchmark remediation, SSH hardening,
  # firewall rules, auditd rules, disabling unused kernel modules, etc.
  provisioner "shell" {
    script = var.hardening_script
  }

  # CVE scanning — Trivy can't scan an AMI ID directly (it scans
  # container images, tarballs, or local filesystems), so the scan has
  # to run here, against the actual filesystem, while we still have
  # shell access inside the build. --exit-code 1 fails the Packer
  # build itself on any CRITICAL/HIGH finding, so a vulnerable image
  # never gets far enough to be registered as an AMI.
  provisioner "shell" {
    inline = [
      "curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin",
      "sudo trivy fs --scanners vuln --severity CRITICAL,HIGH --exit-code 1 --format table /"
    ]
  }

  # Bake in compliance scanning tools so every instance launched from
  # this image can self-report drift, and gate the build itself on
  # the initial CIS compliance score.
  provisioner "shell" {
    inline = [
      "sudo yum install -y openscap-scanner scap-security-guide",
      "sudo oscap xccdf eval --profile cis --report /var/log/cis-baseline-report.html /usr/share/xml/scap/ssg/content/ssg-*-ds.xml"
    ]
  }

  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }
}

