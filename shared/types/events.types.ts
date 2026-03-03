export interface KafkaEvent<T> { eventId: string; timestamp: string; serviceOrigin: string; payload: T; }
export interface FlashEvent { vehicleId: string; tuneId: string; status: 'started' | 'complete' | 'failed'; }
export interface AlertEvent { vehicleId: string; sensor: string; value: number; threshold: number; }
