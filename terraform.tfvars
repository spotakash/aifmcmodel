# =============================================================================
# terraform.tfvars — Minimal configuration
#
# All resource names are derived from project_name in locals.tf.
# SKU is auto-selected based on model_id (see locals.tf model_sku_map).
# =============================================================================
# For Testing Purpose don't keep on using same name as it may create pooling error from old AML Workspace 
project_name = "gtpe" #Change this for each new deployment to avoid pooling errors

# --- Model Deployment ---
# Option A: GTE Large EN v1.5 (CPU OK — auto-selects Standard_DS5_v2)
deployment_name = "gte-large-en-v15-11"
model_id        = "azureml://registries/HuggingFace/models/alibaba-nlp-gte-large-en-v1.5/versions/11"

# Option B: GTE Multilingual Base (GPU required — auto-selects Standard_NC4as_T4_v3)
# deployment_name = "gte-multilingual-base-v2" # Check SKU requirement via Script and have sufficient Subscription Quota before using this model
# model_id        = "azureml://registries/HuggingFace/models/alibaba-nlp-gte-multilingual-base/versions/2"

# --- Private Endpoint Mode ---
# Set to false to enable private networking (VNet, Bastion, PE, Jumpbox VM)
# Set to true (default) for public access — no VNet resources deployed
public_network_access = false

# --- Jumpbox VM (only used when public_network_access = false) ---
jumpbox_admin_password = "YourOwnP@ss1"
