package com.kelner.multiline.controller;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.http.HttpStatus;
import org.springframework.web.server.ResponseStatusException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

@RestController
public class MainController {

    private final Logger logger = LoggerFactory.getLogger(this.getClass());

    @GetMapping("/")
    public ResponseEntity<String> index() {

        return ResponseEntity.ok("Hello World");
    }

    @GetMapping("/exception")
    public ResponseEntity<String> throwException() {

        logger.info("Not an exception");
        int x = 1 / 0;
        return ResponseEntity.ok("1 / 0=" + x);
    }

}