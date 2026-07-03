#!/usr/bin/env bats
# Fast CLI checks — no container build needed.
load helpers

setup() { cpod_isolate_state; }

@test "help выводит команды и режимы ключа" {
  run cpod -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"up"* ]]
  [[ "$output" == *"attach"* ]]
  [[ "$output" == *"--key rw"* ]]
  [[ "$output" == *"--key ro"* ]]
  [[ "$output" == *"--key none"* ]]
}

@test "неизвестный флаг -> ошибка + help + код 2" {
  run cpod --nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"неизвестный флаг"* ]]
  [[ "$output" == *"Команды:"* ]]
}

@test "недопустимый --key отвергается с подсказкой" {
  run cpod up --key bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"--key должен быть rw|ro|none"* ]]
}

@test "две команды сразу -> ошибка" {
  run cpod up down
  [ "$status" -eq 2 ]
  [[ "$output" == *"лишняя команда"* ]]
}

@test "ls на пустом состоянии не падает" {
  skip_if_no_runtime
  make_project
  run cpod ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"NAME"* ]]
}
