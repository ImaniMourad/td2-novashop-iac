variable "login" {
  description = "Identifiant etudiant en minuscules."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.login))
    error_message = "Utiliser uniquement des minuscules et des chiffres."
  }
}

variable "image_name" {
  type    = string
  default = "ubuntu-22.04-asl"
}

variable "flavor_name" {
  type    = string
  default = "m1.medium"
}

variable "keypair_name" {
  type    = string
  default = "asl-key"
}

variable "private_network" {
  type    = string
  default = "asl-net"
}

variable "public_network" {
  type    = string
  default = "public"
}
