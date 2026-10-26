#!/usr/bin/env python3
"""The concierge's Vertex AI key, straight into Secret Manager and optionally a Supabase project.

Makes a key for `concierge-vertex@<gcp-project>` and stores it as a new version of `vertex-service-account`; with
--supabase-ref it also sets `VERTEX_SERVICE_ACCOUNT_JSON` on that Supabase project. See service_account_key.py.

Usage:
  python supabase/tools/set_vertex_key.py <gcp-project>                         # Secret Manager only
  python supabase/tools/set_vertex_key.py <gcp-project> --supabase-ref <ref>    # and the functions
  python supabase/tools/set_vertex_key.py <gcp-project> --supabase-ref <ref> --reuse
                                        # reuse the latest stored key instead of making a new one
"""

from service_account_key import main

if __name__ == "__main__":
    main("concierge-vertex", "vertex-service-account", "VERTEX_SERVICE_ACCOUNT_JSON", __doc__)
