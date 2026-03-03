import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { User } from './user.entity';
import * as bcrypt from 'bcrypt';

@Injectable()
export class UsersService {
  constructor(
    @InjectRepository(User)
    private usersRepository: Repository<User>,
  ) {}

  async findByEmail(email: string): Promise<User | null> {
    return this.usersRepository.findOne({ where: { email } });
  }

  async create(data: { email: string; password: string }): Promise<User> {
    const user = this.usersRepository.create({
      id: crypto.randomUUID(),
      email: data.email,
      password_hash: await bcrypt.hash(data.password, 10),
      role: 'tuner',
    });
    return this.usersRepository.save(user);
  }
}