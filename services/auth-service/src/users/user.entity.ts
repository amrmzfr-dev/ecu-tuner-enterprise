import { Entity, PrimaryColumn, Column, CreateDateColumn } from 'typeorm';

@Entity('users')
export class User {
  @PrimaryColumn('uuid')
  id!: string;

  @Column({ unique: true })
  email!: string;

  @Column({ name: 'password_hash' })
  password_hash!: string;

  @Column()
  role!: string;

  @CreateDateColumn({ name: 'created_at' })
  created_at!: Date;
}