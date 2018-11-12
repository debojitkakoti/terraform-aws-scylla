provider "aws" {
	access_key = "${var.aws_access_key}"
	secret_key = "${var.aws_secret_key}"
	region = "${var.aws_region}"
}

resource "aws_instance" "scylla" {
	ami = "${lookup(var.aws_ami_ubuntu, var.aws_region)}"
	instance_type = "t2.small"
	key_name = "${aws_key_pair.support.key_name}"
	monitoring = true
	availability_zone = "${element(var.aws_availability_zones[var.aws_region], count.index % length(var.aws_availability_zones[var.aws_region]))}"
	subnet_id = "${element(aws_subnet.subnet.*.id, count.index)}"
	security_groups = [
		"${aws_security_group.allow_all.id}",
		"${aws_security_group.cluster.id}",
		"${aws_security_group.cluster-admin.id}",
		"${aws_security_group.cluster-user.id}"
	]

	root_block_device {
		volume_type = "${var.block_device_type}"
		volume_size = "${var.block_device_size}"
		iops = "${var.block_device_iops}"
	}

	credit_specification {
		cpu_credits = "unlimited"
	}

	tags = {
		environment = "${var.environment}"
		cluster_id	= "${var.cluster_id}"
	}

	count = "${var.cluster_count}"
}

resource "aws_instance" "monitor" {
	ami = "${lookup(var.aws_ami_ubuntu, var.aws_region)}"
	instance_type = "t2.small"
	key_name = "${aws_key_pair.support.key_name}"
	monitoring = true
	availability_zone = "${element(var.aws_availability_zones[var.aws_region], 0)}"
	subnet_id = "${element(aws_subnet.subnet.*.id, 0)}"
	security_groups = [
		"${aws_security_group.allow_all.id}",
		"${aws_security_group.cluster.id}",
		"${aws_security_group.cluster-admin.id}",
		"${aws_security_group.cluster-user.id}"
	]

	root_block_device {
		volume_type = "gp2"
		volume_size = "8"
		iops = "100"
	}

	credit_specification {
		cpu_credits = "unlimited"
	}

	tags = {
		environment = "${var.environment}"
		cluster_id	= "${var.cluster_id}"
	}
}

resource "null_resource" "scylla" {
	triggers {
		cluster_instance_ids = "${join(",", aws_instance.scylla.*.id)}"
	}

	connection {
		type = "ssh"
		host = "${element(aws_instance.scylla.*.public_ip, count.index)}"
		user = "ubuntu"
		private_key = "${file(var.private_key)}"
		timeout = "1m"
	}

	provisioner "file" {
		destination = "/tmp/provision-scylla.sh"
		content = <<-EOF
			#!/bin/bash

			set -euo pipefail

			export PRICATE_IP=${element(aws_instance.scylla.*.private_ip, count.index)}
			export PUBLIC_IP=${element(aws_instance.scylla.*.public_ip, count.index)}

			for public_ip in ${join(" ", aws_instance.scylla.*.public_ip)}; do
				echo $$public_ip
			done

			for private_ip in ${join(" ", aws_instance.scylla.*.private_ip)}; do
				echo $$private_ip
			done
		EOF
	}


	provisioner "remote-exec" {
		inline = [
			"chmod +X /tmp/provision-scylla.sh",
			"/tmp/provision-scylla.sh"
		]
	}

	count = "${var.cluster_count}"
}

resource "null_resource" "monitor" {
	triggers {
		cluster_instance_ids = "${aws_instance.monitor.id}"
	}

	connection {
		type = "ssh"
		host = "${aws_instance.monitor.public_ip}"
		user = "ubuntu"
		private_key = "${file(var.private_key)}"
		timeout = "1m"
	}

	provisioner "file" {
		destination = "/tmp/provision-monitor.sh"
		content = <<-EOF
			#!/bin/bash

			set -euo pipefail

			export PRICATE_IP=${aws_instance.monitor.private_ip}
			export PUBLIC_IP=${aws_instance.monitor.public_ip}

			for public_ip in ${join(" ", aws_instance.scylla.*.public_ip)}; do
				echo $$public_ip
			done

			for private_ip in ${join(" ", aws_instance.scylla.*.private_ip)}; do
				echo $$private_ip
			done
		EOF
	}


	provisioner "remote-exec" {
		inline = [
			"chmod +X /tmp/provision-monitor.sh",
			"/tmp/provision-monitor.sh"
		]
	}

	count = "${var.cluster_count}"
}



resource "aws_key_pair" "support" {
	key_name = "support-key"
	public_key = "${file(var.public_key)}"
}

resource "aws_vpc" "vpc" {
	cidr_block = "10.0.0.0/16"

	tags = {
		environment = "${var.environment}"
		cluster_id	= "${var.cluster_id}"
	}
}

resource "aws_internet_gateway" "vpc_igw" {
	vpc_id = "${aws_vpc.vpc.id}"

	tags = {
		environment = "${var.environment}"
		cluster_id	= "${var.cluster_id}"
	}
}

resource "aws_subnet" "subnet" {
	availability_zone = "${element(var.aws_availability_zones[var.aws_region], count.index % length(var.aws_availability_zones[var.aws_region]))}"
	cidr_block = "${format("10.0.%d.0/24", count.index)}"
	vpc_id = "${aws_vpc.vpc.id}"
	map_public_ip_on_launch = true

	tags = {
		environment = "${var.environment}"
		cluster_id	= "${var.cluster_id}"
	}

	count = "${var.cluster_count}"
}

resource "aws_route_table" "public" {
	vpc_id = "${aws_vpc.vpc.id}"

	route = {
		cidr_block = "0.0.0.0/0"
		gateway_id = "${aws_internet_gateway.vpc_igw.id}"
	}

	tags = {
		environment = "${var.environment}"
		cluster_id	= "${var.cluster_id}"
	}
}

resource "aws_route_table_association" "public" {
	route_table_id = "${aws_route_table.public.id}"
	subnet_id = "${element(aws_subnet.subnet.*.id, count.index)}"

	count = "${var.cluster_count}"
}

resource "aws_security_group" "allow_all" {
	name = "allow_all"
	description = "Allow all inbound and outbound traffic"
	vpc_id = "${aws_vpc.vpc.id}"

	egress = {
		cidr_blocks = ["0.0.0.0/0"]
		from_port = 0
		protocol = "-1"
		self = true
		to_port = 0
	}

	ingress = {
		cidr_blocks = ["0.0.0.0/0"]
		from_port = 0
		protocol = "-1"
		self = true
		to_port = 0
	}

	tags = {
		environment = "${var.environment}"
		cluster_id	= "${var.cluster_id}"
	}
}

resource "aws_security_group" "cluster" {
	name = "cluster"
	description = "Security Group for inner cluster connections"
	vpc_id = "${aws_vpc.vpc.id}"

	tags = {
		environment = "${var.environment}"
		cluster_id	= "${var.cluster_id}"
	}
}

resource "aws_security_group_rule" "cluster-nodes-7000" {
	type = "ingress"
	name = "cluster-nodes-7000"
	cidr_blocks = ["${append(aws_instance.scylla.*.public_ip, aws_instance.monitor.public_ip)}"]
	from_port = 7000
	to_port = 7000
	protocol = "tcp"
	self = true
}

resource "aws_security_group_rule" "cluster-nodes-7001" {
	type = "ingress"
	name = "cluster-nodes-7001"
	cidr_blocks = ["${append(aws_instance.scylla.*.public_ip, aws_instance.monitor.public_ip)}"]
	from_port = 7001
	to_port = 7001
	protocol = "tcp"
	self = true
}

resource "aws_security_group_rule" "cluster-monitor-9100" {
	type = "ingress"
	name = "cluster-monitor-9100"
	cidr_blocks = ["${aws_instance.monitor.public_ip}"]
	from_port = 9100
	to_port = 9100
	protocol = "tcp"
	self = true
}

resource "aws_security_group_rule" "cluster-monitor-9180" {
	type = "ingress"
	name = "cluster-monitor-9180"
	cidr_blocks = ["${aws_instance.monitor.public_ip}"]
	from_port = 9180
	to_port = 9180
	protocol = "tcp"
	self = true
}

resource "aws_security_group" "cluster-admin" {
	name = "cluster-admin"
	description = "Security Group for the admin of cluster #${var.cluster_id}"
	vpc_id = "${aws_vpc.vpc.id}"

	egress = {
		cidr_blocks = ["0.0.0.0/0"]
		from_port = 0
		to_port = 0
		protocol = "-1"
		self = true
	}

	ingress = {
		cidr_blocks = ${var.cluster_admin_cidr}
		from_port = 22
		to_port = 22
		protocol = "tcp"
		self = true
	}

	ingress = {
		cidr_blocks = ${var.cluster_admin_cidr}
		from_port = 3000
		to_port = 3000
		protocol = "tcp"
		self = true
	}

	ingress = {
		cidr_blocks = ${var.cluster_admin_cidr}
		from_port = 9042
		to_port = 9042
		protocol = "tcp"
		self = true
	}


	ingress = {
		cidr_blocks = ${var.cluster_admin_cidr}
		from_port = 9090
		to_port = 9090
		protocol = "tcp"
		self = true
	}


	ingress = {
		cidr_blocks = ${var.cluster_admin_cidr}
		from_port = 9093
		to_port = 9093
		protocol = "tcp"
		self = true
	}

	tags = {
		environment = "${var.environment}"
		cluster_id	= "${var.cluster_id}"
	}
}

resource "aws_security_group" "cluster-user" {
	name = "cluster-user"
	description = "Security Group for the user of cluster #${var.cluster_id}"
	vpc_id = "${aws_vpc.vpc.id}"

	egress = {
		cidr_blocks = ["0.0.0.0/0"]
		from_port = 0
		protocol = "-1"
		self = true
		to_port = 0
	}

	ingress = {
		cidr_blocks = ${var.cluster_user_cidr}
		from_port = 9042
		to_port = 9042
		protocol = "tcp"
		self = true
	}


	ingress = {
		cidr_blocks = ${var.cluster_user_cidr}
		from_port = 9160
		to_port = 9160
		protocol = "tcp"
		self = true
	}

	tags = {
		environment = "${var.environment}"
		cluster_id	= "${var.cluster_id}"
	}
}

variable "aws_access_key" { }
variable "aws_secret_key" { }
variable "aws_region" { }

variable "cluster_id" { }
variable "cluster_count" { default = 1 }

variable "block_device_type" { }
variable "block_device_size" { }
variable "block_device_iops" { }

variable "environment" { default = "development" }
variable "private_key" { default = "keys/support.pem" }
variable "public_key"	{ default = "keys/support.pub" }
