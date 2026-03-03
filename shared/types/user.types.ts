export type Role = 'super_admin' | 'master_tuner' | 'tuner' | 'viewer' | 'customer';
export interface User { id: string; email: string; role: Role; }
