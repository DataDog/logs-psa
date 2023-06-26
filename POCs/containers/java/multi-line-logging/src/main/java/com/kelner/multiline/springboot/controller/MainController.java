package com.kelner.multiline.springboot.controller;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.http.HttpStatus;
import org.springframework.web.server.ResponseStatusException;

@RestController
public class MainController {

    @GetMapping("/")
    public ResponseEntity<String> index() {

        return ResponseEntity.ok("Hello World");
    }

}
