export interface MapCell { value: number; isModified: boolean; }
export interface MapTable { id: string; name: string; rows: number; cols: number; cells: MapCell[][]; }
export interface TuneMap { id: string; vehicleId: string; tables: MapTable[]; version: number; }
