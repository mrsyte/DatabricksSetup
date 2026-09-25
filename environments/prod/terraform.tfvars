environment         = "prod"
location            = "centralus"
hub_subscription_id = "aaaaaaaa-bbbb-cccc-dddd-000000000001"   # replace
tenant_id           = "aaaaaaaa-bbbb-cccc-dddd-000000000002"   # replace

app_name    = "databricks-platform"
owner       = "data-platform-team@contoso.com"
cost_center = "data-platform-9001"

databricks_admins_group_object_id = "aaaaaaaa-bbbb-cccc-dddd-000000000099"   # replace

hub_vnet_address_space  = "10.0.0.0/16"
adb_vnet_address_space  = "10.1.0.0/16"
vpn_client_address_pool = ["172.16.0.0/22"]
