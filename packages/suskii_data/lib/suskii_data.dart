/// Suskii Errands data layer. Exposes the mock implementations and, from M9,
/// the Supabase implementations behind the same domain interfaces.
library;

export 'src/mock/fixtures.dart';
export 'src/mock/mock_behavior.dart';
export 'src/mock/mock_repositories.dart';
export 'src/mock/server_sim.dart';
export 'src/supabase/supabase_auth_repository.dart';
export 'src/supabase/supabase_error_mapping.dart';
export 'src/supabase/supabase_gateway.dart';
