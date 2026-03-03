export interface SensorReading { pid: string; value: number; unit: string; timestamp: string; }
export interface DatalogSession { id: string; vehicleId: string; startTime: string; readings: SensorReading[]; }
